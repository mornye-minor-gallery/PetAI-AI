import Foundation

public protocol LLMRuntime: Sendable {
    var state: RuntimeState { get async }

    func prepare(modelURL: URL) async throws
    func startConversation(configuration: ConversationConfiguration) async throws
    func generateStream(prompt: String) async throws -> AsyncThrowingStream<String, Error>
    func cancel() async
    func resetConversation() async throws
    func unload() async throws
}

public extension LLMRuntime {
    func generate(prompt: String) async throws -> String {
        var response = ""

        for try await chunk in try await generateStream(prompt: prompt) {
            response += chunk
        }

        return response
    }
}
