import Foundation
public struct BenchmarkInfo {}
public protocol TextSession: AnyObject, Sendable {
    func streamText(_ prompt: String, thinkingEnabled: Bool, maxOutputTokens: Int) -> AsyncThrowingStream<String, Error>
    func waitUntilIdle() async
    func cancel() throws
    func getTokenCount() throws -> Int
}
struct SamplerConfig { let topK: Int; let topP: Float; let temperature: Float; let seed: Int }
public enum Role: String, Sendable { case system, model, user }
public struct Message: Sendable {
    let text: String
    let role: Role
    init(_ text: String, role: Role = .user) { self.text=text; self.role=role }
}
actor Engine {
    func renderTextRequest(systemPrompt: String?, history: [Message], userPrompt: String, thinkingEnabled: Bool) throws -> String {
        "BOS" + (systemPrompt ?? "") + history.map {
            "<|turn>" + $0.role.rawValue + "\n" + $0.text + "<turn|>\n"
        }.joined() + "<|turn>user\n" + userPrompt + "<|turn>model\n"
    }
    func countTokens(_ text: String) throws -> Int { text.utf8.count }
    func tokenIDs(_ text: String) throws -> [Int32] { text.utf8.map(Int32.init) }
    func startTokenText() throws -> String { "BOS" }
}
