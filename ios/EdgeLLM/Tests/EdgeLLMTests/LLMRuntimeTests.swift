import Foundation
import Testing
@testable import EdgeLLM

private actor StreamingStubRuntime: LLMRuntime {
    var state: RuntimeState = .ready

    func prepare(modelURL: URL) async throws {}

    func startConversation(
        configuration: ConversationConfiguration
    ) async throws {}

    func generateStream(
        prompt: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("Hello")
            continuation.yield(", world")
            continuation.finish()
        }
    }

    func cancel() async {}
    func resetConversation() async throws {}
    func unload() async throws {}
}

@Test func generateCollectsStreamingChunks() async throws {
    let runtime = StreamingStubRuntime()

    let response = try await runtime.generate(prompt: "Hello")

    #expect(response == "Hello, world")
}
