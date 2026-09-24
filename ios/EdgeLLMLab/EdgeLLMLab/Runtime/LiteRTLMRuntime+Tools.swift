import Foundation
import OSLog

#if canImport(EdgeLLM)
import EdgeLLM
#endif

#if canImport(LiteRTLM)
import LiteRTLM
#endif

#if canImport(LiteRTLM) || canImport(CLiteRTLM)
extension LiteRTLMRuntime: NativeToolProposalGenerating {
    func generateFunctionCall(
        _ request: NativeToolGenerationRequest
    ) async throws -> NativeToolFunctionCall {
        try requireNativeIdle()
        guard let engine else {
            throw RuntimeError.modelNotPrepared
        }

        let generationID = UUID()
        activeGenerationID = generationID
        cancelRequested = false
        currentState = .generating
        var captured: NativeToolFunctionCall?
        var failure: Error?
        do {
            try await LiteRTLMNativeToolCallCapture.shared.begin(
                expectedTool: request.selectedTool
            )
            let sampling = slmConfiguration.generation
                .deterministicSampling
            let sampler = try SamplerConfig(
                topK: sampling.samplerTopK,
                topP: sampling.topP,
                temperature: sampling.temperature
            )
            let configuration = ConversationConfig(
                systemMessage: Message(
                    request.systemPrompt,
                    role: .system
                ),
                tools: [
                    LiteRTLMNativeToolFactory.makeTool(
                        for: request.selectedTool
                    ),
                ],
                samplerConfig: sampler,
                thinkingConfig: ThinkingConfig(
                    enableThinking: request.reasoningEnabled
                )
            )
            let toolConversation = try await engine.createConversation(
                with: configuration
            )
            guard !cancelRequested else { throw RuntimeError.generationCancelled }
            activeNativeConversation = toolConversation
            isolatedConversation = toolConversation
            let source = toolConversation.sendMessageStream(
                Message(request.userMessage),
                extraContext: [
                    "enable_thinking": request.reasoningEnabled,
                ],
                maxOutputTokens: slmConfiguration.dialogueBudget.outputTokens,
                thinkingConfig: ThinkingConfig(
                    enableThinking: request.reasoningEnabled
                )
            )
            for try await _ in source { }
            await waitForNativeCompletion(toolConversation)
            guard !cancelRequested else { throw RuntimeError.generationCancelled }
            captured = try await LiteRTLMNativeToolCallCapture.shared.finish()
        } catch {
            failure = error
            // Some models emit a valid captured proposal before their stream reports an error.
            captured = try? await LiteRTLMNativeToolCallCapture.shared.finish()
            await LiteRTLMNativeToolCallCapture.shared.cancel()
        }
        // Capture actor awaits can admit a new cancel call, so drain after the last one.
        if let activeNativeConversation { await waitForNativeCompletion(activeNativeConversation) }
        let wasCancelled = cancelRequested || failure is CancellationError
            || (failure as? RuntimeError) == .generationCancelled
        finishIsolatedGeneration(id: generationID)
        if wasCancelled { throw RuntimeError.generationCancelled }
        if let captured { return captured }
        throw failure ?? LiteRTLMNativeToolProposalError.missingToolCall
    }
}
#endif
