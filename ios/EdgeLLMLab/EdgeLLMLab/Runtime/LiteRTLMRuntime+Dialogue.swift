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
        guard !isPreparingInput, currentState != .generating, currentState != .preparingModel else {
            throw RuntimeError.runtimeBusy
        }
    }

    /// One exclusive operation: select/measure, then create the matching conversation.
    /// The measured engine cannot be unloaded or used for generation across awaits.
    func prepareDialogue(input: DialoguePromptInput, policy: DialoguePromptPolicy,
                         thinkingEnabled: Bool, telemetryCandidateCount: Int?) async throws -> PreparedDialogue {
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
        try await replaceConversation(configuration: .init(systemPrompt: prepared.systemPrompt,
            temperature: sampling.temperature, topK: sampling.samplerTopK, topP: sampling.topP,
            maxOutputTokens: budget.outputTokens, topKTelemetryCandidateCount: telemetryCandidateCount,
            thinkingEnabled: thinkingEnabled))
        try Task.checkCancellation()
        guard !cancelRequested else { throw RuntimeError.generationCancelled }
        conversationDialogueBudget = budget
        return prepared
    }

    /// Retries have a populated KV cache and must reserve space again before sending.
    func checkConversationBudget(_ conversation: Conversation, prompt: String,
                                 budget: DialogueTokenBudget) async throws {
        guard let engine else { throw RuntimeError.modelNotPrepared }
        let cached = try conversation.getTokenCount()
        let rendered = try conversation.renderMessageIntoString(Message(prompt))
        let submitted = try await engine.countTokens(rendered)
        guard cached >= 0, submitted >= 0, cached <= Int.max - submitted,
              try conversation.getTokenCount() == cached else {
            throw DialogueTokenBudgetError.invalidMeasurement
        }
        let total = cached + submitted
        guard total <= budget.contextTokens - budget.outputTokens else {
            throw DialogueTokenBudgetError.exceeded(input: total, reservedOutput: budget.outputTokens,
                                                    capacity: budget.contextTokens)
        }
    }
}
