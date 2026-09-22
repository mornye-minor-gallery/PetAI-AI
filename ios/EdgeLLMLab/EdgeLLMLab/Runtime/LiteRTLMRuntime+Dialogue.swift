import Foundation
#if canImport(EdgeLLM)
import EdgeLLM
#endif
#if canImport(LiteRTLM)
import LiteRTLM
#endif

private struct LiteRTLMDialogueMeasurer: DialogueTokenMeasuring {
    let identifier = "litert-lm-native-text"
    let engine: Engine
    let thinkingEnabled: Bool

    func countTokens(_ text: String) async throws -> Int {
        try Task.checkCancellation()
        return try await engine.countTokens(text)
    }

    func measureInput(_ input: DialogueModelInput) async throws -> Int {
        try Task.checkCancellation()
        return try await engine.measureTextPrompt(systemPrompt: input.systemPrompt,
            userPrompt: input.userPrompt, thinkingEnabled: thinkingEnabled).totalTokens
    }
}

extension LiteRTLMRuntime {
    func requireNativeIdle() throws {
        guard activeGenerationID == nil, !isPreparingInput, currentState != .generating, currentState != .preparingModel else {
            throw RuntimeError.runtimeBusy
        }
    }

    /// One exclusive operation: select/measure, then prepare the matching full input.
    /// The measured engine cannot be unloaded or used for generation across awaits.
    func prepareDialogue(input: DialoguePromptInput, policy: DialoguePromptPolicy,
                         thinkingEnabled: Bool) async throws -> PreparedDialogue {
#if RESOURCE_BENCH
        RuntimeResourceTrace.mark("dialogue.prepare.begin")
        defer { RuntimeResourceTrace.mark("dialogue.prepare.exit") }
#endif
        try requireNativeIdle()
        guard let engine else { throw RuntimeError.modelNotPrepared }
        isPreparingInput = true
        cancelRequested = false
        defer { isPreparingInput = false }
        let budget = slmConfiguration.dialogueBudget
        let prepared = try await DialoguePromptComposer.prepare(input: input, policy: policy,
            tokenBudget: budget, measurer: LiteRTLMDialogueMeasurer(engine: engine, thinkingEnabled: thinkingEnabled))
        try Task.checkCancellation()
        guard !cancelRequested else { throw RuntimeError.generationCancelled }
        let sampling = slmConfiguration.generation.responseSampling
#if RESOURCE_BENCH
        RuntimeResourceTrace.mark("dialogue.budget", [
            "context_tokens": String(budget.contextTokens),
            "output_tokens": String(budget.outputTokens)
        ])
#endif
        try await reuseCachedConversation(configuration: .init(systemPrompt: prepared.systemPrompt,
            temperature: sampling.temperature, topK: sampling.samplerTopK, topP: sampling.topP,
            maxOutputTokens: budget.outputTokens, thinkingEnabled: thinkingEnabled))
        try Task.checkCancellation()
        guard !cancelRequested else { throw RuntimeError.generationCancelled }
        conversationDialogueBudget = budget
        return prepared
    }

    /// The authoritative app history replaces each turn's dynamic input. Sampling
    /// changes require a new native session; changing text does not.
    func reuseCachedConversation(configuration: ConversationConfiguration) async throws {
        guard let engine else { throw RuntimeError.modelNotPrepared }
        let previous = conversationConfiguration
        let compatible = previous?.temperature == configuration.temperature
            && previous?.topK == configuration.topK && previous?.topP == configuration.topP
            && previous?.maxOutputTokens == configuration.maxOutputTokens
        if !compatible || !(conversation is CachedSession) {
            conversation = nil
            let sampler = try SamplerConfig(topK: configuration.topK, topP: configuration.topP,
                temperature: configuration.temperature)
            conversation = try await engine.createCachedSession(sampler: sampler,
                maxOutputTokens: configuration.maxOutputTokens)
        }
        guard let cached = conversation as? CachedSession else { throw RuntimeError.conversationNotStarted }
        try cached.replaceInput(systemPrompt: configuration.systemPrompt)
        conversationConfiguration = configuration
        currentState = .ready
    }

    /// Retries have a populated KV cache and must reserve space again before sending.
    func checkConversationBudget(_ conversation: any TextSession, prompt: String,
                                 budget: DialogueTokenBudget) async throws {
        guard let engine else { throw RuntimeError.modelNotPrepared }
        let total: Int
        if let cached = conversation as? CachedSession {
            total = try await cached.measureInput(prompt, thinkingEnabled: conversationConfiguration?.thinkingEnabled ?? false)
        } else if let ordinary = conversation as? Conversation {
            let cached = try ordinary.getTokenCount()
            let rendered = try ordinary.renderMessageIntoString(Message(prompt))
            let submitted = try await engine.countTokens(rendered)
            guard cached >= 0, submitted >= 0, cached <= Int.max - submitted,
                  try ordinary.getTokenCount() == cached else { throw DialogueTokenBudgetError.invalidMeasurement }
            total = cached + submitted
        } else { throw DialogueTokenBudgetError.invalidMeasurement }
        guard total <= budget.contextTokens - budget.outputTokens else {
            throw DialogueTokenBudgetError.exceeded(input: total, reservedOutput: budget.outputTokens,
                                                    capacity: budget.contextTokens)
        }
    }
}
