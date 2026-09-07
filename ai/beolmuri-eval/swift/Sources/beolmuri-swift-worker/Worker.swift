import EdgeLLM
import Foundation

// Runtime overrides belong to the evaluation executable, not product persona policy.
private struct EvaluationConfiguration: Decodable {
    let persona: PersonaResponseConfiguration
    let thinking: Bool?

    private enum CodingKeys: String, CodingKey { case thinking }

    init(from decoder: Decoder) throws {
        persona = try PersonaResponseConfiguration(from: decoder)
        thinking = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(Bool.self, forKey: .thinking)
    }

    func snapshot() throws -> [String: Any] {
        var value = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(persona)
        ) as! [String: Any]
        if let thinking { value["thinking"] = thinking }
        return value
    }
}

private struct Request: Decodable {
    let id: String
    let operation: String
    let configuration: EvaluationConfiguration
    let characterName: String?
    let userMessage: String?
    let primaryChunks: [String]?
    let retryChunks: [String]?
}

private enum WorkerError: Error { case retryRequired, invalidRequest }

@main struct Worker {
    static func stream(_ chunks: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    private static func handle(_ request: Request) async throws -> [String: Any] {
        switch request.operation {
        case "prepare":
            guard let message = request.userMessage, !message.isEmpty else {
                throw WorkerError.invalidRequest
            }
            let prompts = try RoutedPersonaPromptRegistry().load()
            let profile = UserProfileContext(characterName: request.characterName ?? "엘레나")
            let generation = SLMConfiguration.production.generation
            return [
                "status": "prepared",
                "configuration": try request.configuration.snapshot(),
                "system_prompt": prompts.responseSystemPrompt(
                    activeCard: prompts.card(scene: .general), userProfileContext: profile,
                    configuration: request.configuration.persona
                ),
                "user_prompt": RoutedPersonaSessionContext().responseInput(
                    memoryAugmentedUserMessage: MemoryPromptBuilder.build(userMessage: message, memories: [])
                ),
                "scope": "single-turn-fixed-general-empty-memory",
                "scene": "GENERAL", "recalled_memories": [], "history": [],
                "memory_store": "disabled-fixture",
                "sampling": [
                    "temperature": generation.responseSampling.temperature,
                    "top_k": generation.responseSampling.samplerTopK,
                    "top_p": generation.responseSampling.topP,
                    "max_output_tokens": generation.maxOutputTokens,
                    "thinking": request.configuration.thinking ?? generation.responseThinkingDefault,
                    "filter_channel_content_from_kv_cache": true
                ]
            ]
        case "process":
            guard let chunks = request.primaryChunks else { throw WorkerError.invalidRequest }
            do {
                let outcome = try await MemoryTaggedChatProcessor.run(
                    configuration: request.configuration.persona,
                    primaryStream: { stream(chunks) },
                    retryStream: {
                        guard let retry = request.retryChunks else { throw WorkerError.retryRequired }
                        return stream(retry)
                    },
                    receiveVisibleText: { _ in }
                )
                return [
                    "status": "processed", "visible_text": outcome.visibleText,
                    "raw_primary": outcome.primary.rawText,
                    "raw_retry": outcome.retry?.rawText as Any? ?? NSNull(),
                    "header_syntax": outcome.primary.syntax.rawValue,
                    "control_text": outcome.primary.controlText,
                    "primary_memory_decision": outcome.primary.decision?.rawValue as Any? ?? NSNull(),
                    "eligible_commit_decision": outcome.commitDecision?.rawValue as Any? ?? NSNull(),
                    "retry_attempted": outcome.retryAttempted,
                    "has_visible_response": outcome.hasVisibleResponse,
                    "memory_write_performed": false
                ]
            } catch WorkerError.retryRequired {
                return ["status": "retry_required", "retry_prompt": MemoryTaggedChatPrompt.answerOnlyRetry]
            }
        default: throw WorkerError.invalidRequest
        }
    }

    static func main() async {
        while let line = readLine() {
            var requestID: Any = NSNull()
            do {
                let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                requestID = request.id
                var result = try await handle(request)
                result["id"] = request.id
                result["protocol_version"] = 1
                try emit(result)
            } catch {
                try? emit(["id": requestID, "protocol_version": 1,
                           "status": "error", "error": String(describing: error)])
            }
        }
    }

    static func emit(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
