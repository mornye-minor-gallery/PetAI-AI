import Foundation

/// Runtime-facing surface shared by ordinary conversations and replaceable full
/// text requests. A missing native counter stays missing instead of being estimated.
public protocol TextSession: AnyObject, Sendable {
    func streamText(_ prompt: String, thinkingEnabled: Bool, maxOutputTokens: Int) -> AsyncThrowingStream<String, Error>
    func waitUntilIdle() async
    func cancel() throws
    func getTokenCount() throws -> Int
    func getBenchmarkInfo() throws -> BenchmarkInfo
}

extension Conversation: TextSession {
    public func streamText(_ prompt: String, thinkingEnabled: Bool, maxOutputTokens: Int) -> AsyncThrowingStream<String, Error> {
        let source = sendMessageStream(Message(prompt), extraContext: ["enable_thinking": thinkingEnabled],
            maxOutputTokens: maxOutputTokens, thinkingConfig: ThinkingConfig(enableThinking: thinkingEnabled))
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await message in source { continuation.yield(message.toString) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}
