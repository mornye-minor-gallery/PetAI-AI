#if RESOURCE_BENCH
import Foundation
import EdgeLLM
import LiteRTLM

@MainActor final class InferenceBenchWorkload: BenchWorkload {
    private var runtime: LiteRTLMRuntime?
    var journal: RunJournal?
    func prepare(plan: BenchPlan, modelURL: URL) async throws {
        let sampling = SLMConfiguration.Sampling(
            temperature: plan.generation.temperature,
            samplerTopK: plan.generation.top_k,
            topP: plan.generation.top_p
        )
        // The benchmark manifest is the source of truth for inference settings.
        // Keep this configuration independent of product-bundle resources so a
        // packaging failure cannot be mistaken for a model or device failure.
        let configuration = SLMConfiguration(
            id: "resource-bench-v1",
            memory: .init(recallLimit: 1, promptByteBudget: 1, minimumSimilarity: 0),
            generation: .init(
                responseSampling: sampling,
                deterministicSampling: sampling,
                maxOutputTokens: plan.generation.max_output_tokens,
                responseThinkingDefault: plan.generation.thinking_enabled,
                routerThinkingEnabled: false,
                toolReasoningEnabled: false
            ),
            persona: .init(recentMessageLimit: 0),
            runtimeSafety: .init(cancellationTimeoutSeconds: 15),
            dialogueBudget: .init(memoryTokens: 0, contextTokens: plan.generation.context_tokens,
                                 outputTokens: plan.generation.max_output_tokens)
        )
        let runtime = LiteRTLMRuntime(
            configuration: configuration,
            collectNativeBenchmark: true
        )
        self.runtime = runtime
        try await runtime.prepare(modelURL: modelURL)
    }
    func perform(_ input: BenchInput, generation: BenchGeneration) async throws -> String {
        guard let runtime else { throw BenchFailure.invalid("runtime_not_prepared") }
        try await runtime.prepareBenchmarkInput(input, generation: generation)
        guard let journal else { throw BenchFailure.invalid("generation_journal_not_attached") }
        let generationID = UUID().uuidString.lowercased()
        let payload = ["turn_id": input.id, "generation_id": generationID]
        try journal.event("generation_start", payload: payload)
        do {
            let stream = try await runtime.generateStream(prompt: input.user_prompt)
            var output = ""
            for try await chunk in stream { output += chunk }
            guard let metrics = await runtime.latestGenerationMetrics() else {
                try journal.event("native_inference_metrics_unavailable", payload: payload.merging([
                    "error": "missing_native_inference_metrics",
                ]) { _, new in new })
                throw BenchFailure.invalid("missing_native_inference_metrics")
            }
            if let error = metrics.measurementError {
                try journal.event("native_inference_metrics_unavailable", payload: payload.merging([
                    "error": error,
                ]) { _, new in new })
                throw BenchFailure.invalid("invalid_native_inference_metrics")
            }
            guard let prefillTokens = metrics.prefillTokens,
                  let prefillTokensPerSecond = metrics.prefillTokensPerSecond,
                  let decodeTokens = metrics.decodeTokens,
                  let decodeTokensPerSecond = metrics.decodeTokensPerSecond else {
                throw BenchFailure.invalid("incomplete_native_inference_metrics")
            }
            var metricPayload: [String: Any] = payload
            metricPayload["kv_tokens_before"] = metrics.kvTokensBefore
            metricPayload["kv_tokens_after"] = metrics.kvTokensAfter
            metricPayload["native_ttft_seconds"] = metrics.nativeTTFTSeconds
            metricPayload["first_response_seconds"] = metrics.firstResponseSeconds
            metricPayload["generation_elapsed_seconds"] = metrics.generationElapsedSeconds
            if let cache = metrics.cache {
                metricPayload["cache_session_id"] = cache.sessionID
                metricPayload["finish_reason"] = cache.finishReason
                metricPayload["input_tokens"] = cache.inputTokens
                metricPayload["matching_input_prefix_tokens"] = cache.matchingInputPrefixTokens
                metricPayload["kv_counter_status"] = "unsupported_session_c_api"
            }
            metricPayload["prefill_tokens"] = prefillTokens
            metricPayload["prefill_tokens_per_second"] = prefillTokensPerSecond
            metricPayload["decode_tokens"] = decodeTokens
            metricPayload["decode_tokens_per_second"] = decodeTokensPerSecond
            try journal.event("native_inference_metrics", payload: metricPayload)
            try journal.event("generation_end", payload: payload)
            return output
        } catch {
            try journal.event("generation_failed", payload: payload.merging(["error": String(describing: error)]) { _, new in new })
            throw error
        }
    }
    func cancel() async { await runtime?.cancel() }
}

extension LiteRTLMRuntime {
    func prepareBenchmarkInput(_ input: BenchInput, generation: BenchGeneration) async throws {
        try requireNativeIdle()
        guard let engine else { throw RuntimeError.modelNotPrepared }
        isPreparingInput = true
        defer { isPreparingInput = false }
        let size = try await engine.measureTextPrompt(systemPrompt: input.system_prompt,
            userPrompt: input.user_prompt, thinkingEnabled: generation.thinking_enabled)
        guard size.totalTokens <= generation.context_tokens - generation.max_output_tokens else {
            throw BenchFailure.invalid("prepared_input_exceeds_context")
        }
        try Task.checkCancellation()
        let configuration = ConversationConfiguration(systemPrompt: input.system_prompt,
            temperature: generation.temperature, topK: generation.top_k, topP: generation.top_p,
            maxOutputTokens: generation.max_output_tokens, thinkingEnabled: generation.thinking_enabled)
        if generation.conversation_mode == "cached_full_prompt" {
            try await reuseCachedConversation(configuration: configuration)
        } else {
            try await replaceConversation(configuration: configuration)
        }
        conversationDialogueBudget = slmConfiguration.dialogueBudget
    }
}
#endif
