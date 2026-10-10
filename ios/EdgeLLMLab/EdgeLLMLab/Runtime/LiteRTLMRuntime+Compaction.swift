import Foundation
#if canImport(EdgeLLM)
import EdgeLLM
#endif
#if canImport(LiteRTLM)
import LiteRTLM
#endif

extension LiteRTLMRuntime {
    nonisolated var identifier: String { "litert-lm-native-text" }

    func countTokens(_ text: String) async throws -> Int {
        try requireNativeIdle()
        guard let engine else { throw RuntimeError.modelNotPrepared }
        isPreparingInput = true
        defer { isPreparingInput = false }
        return try await engine.countTokens(text)
    }

    func measureInput(_ input: DialogueModelInput) async throws -> Int {
        try requireNativeIdle()
        guard let engine else { throw RuntimeError.modelNotPrepared }
        isPreparingInput = true
        defer { isPreparingInput = false }
        return try await engine.measureTextPrompt(systemPrompt: nil,
            initialMessages: input.initialMessages.map(\.nativeMessage),
            userPrompt: input.currentUserMessage,
            thinkingEnabled: conversationConfiguration?.thinkingEnabled ?? false).totalTokens
    }

    func generateDialogueSummary(_ text: String, maximumTokens: Int) async throws -> String {
        try requireNativeIdle()
        // One engine, one live KV allocation. The old dialogue checkpoint stays
        // on disk until the replacement context is durably committed.
        conversation = nil
        conversationDialogueBudget = nil
        return try await generateIsolated(systemPrompt: DialogueContextCompactor.summaryInstruction,
            userMessage: text, sampling: slmConfiguration.generation.deterministicSampling,
            thinkingEnabled: false, maxOutputTokens: maximumTokens)
    }

    func prefillDialogueContext(_ input: DialogueModelInput, thinkingEnabled: Bool) async throws {
        try requireNativeIdle()
        isPreparingInput = true
        defer { isPreparingInput = false }
        try await reuseCachedConversation(configuration: dialogueConversationConfiguration(thinkingEnabled: thinkingEnabled),
            initialMessages: input.initialMessages.map(\.nativeMessage))
        guard let cached = conversation as? CachedSession else { throw RuntimeError.conversationNotStarted }
        do { try await cached.prefillInput(input.currentUserMessage, thinkingEnabled: thinkingEnabled) }
        catch { currentState = .failed(message: error.localizedDescription); throw error }
        conversationDialogueBudget = slmConfiguration.dialogueBudget
    }
}
