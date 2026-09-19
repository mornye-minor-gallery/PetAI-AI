#if RESOURCE_BENCH
import Foundation
import EdgeLLM
import LiteRTLM

@MainActor final class InferenceBenchWorkload: BenchWorkload {
    private var runtime: LiteRTLMRuntime?
    var journal: RunJournal?
    func prepare(plan: BenchPlan, modelURL: URL) async throws {
        let base = SLMConfiguration.production
        let configuration = SLMConfiguration(id: "resource-bench-v1", memory: base.memory,
            generation: base.generation, persona: base.persona, diagnostics: base.diagnostics,
            runtimeSafety: base.runtimeSafety,
            dialogueBudget: .init(memoryTokens: 0, contextTokens: plan.generation.context_tokens,
                                 outputTokens: plan.generation.max_output_tokens))
        let runtime = LiteRTLMRuntime(configuration: configuration)
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
        try await replaceConversation(configuration: .init(systemPrompt: input.system_prompt,
            temperature: generation.temperature, topK: generation.top_k, topP: generation.top_p,
            maxOutputTokens: generation.max_output_tokens, thinkingEnabled: generation.thinking_enabled))
    }
}
#endif
