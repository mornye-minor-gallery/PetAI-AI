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

        currentState = .generating
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
                filterChannelContentFromKVCache: true,
                maxOutputTokens: slmConfiguration.generation
                    .maxOutputTokens
            )
            let toolConversation = try await engine.createConversation(
                with: configuration
            )
            _ = try await toolConversation.sendMessage(
                Message(request.userMessage),
                extraContext: [
                    "enable_thinking": request.reasoningEnabled,
                ]
            )
            let call = try await LiteRTLMNativeToolCallCapture.shared.finish()
            currentState = .ready
            return call
        } catch {
            if let call = try? await
                LiteRTLMNativeToolCallCapture.shared.finish()
            {
                currentState = .ready
                return call
            }
            await LiteRTLMNativeToolCallCapture.shared.cancel()
            currentState = .ready
            throw error
        }
    }
}
#endif
