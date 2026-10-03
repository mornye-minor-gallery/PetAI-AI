import EdgeLLM
import Foundation

// Runtime overrides belong to the evaluation executable, not product persona policy.
private struct EvaluationConfiguration: Decodable {
    let persona: PersonaResponseConfiguration
    let dialogueContent: DialogueContent?
    let personaCore: String?
    let thinking: Bool?
    let sampling: EvaluationSampling?
    let nameRulePlacement: NameRulePlacement?
    let authorsNote: AuthorsNoteSettings?
    let authoredText: DialogueTextSettings?
    let worldInfo: WorldInfoSettings?

    private enum CodingKeys: String, CodingKey { case dialogueContent, personaCore, thinking, sampling, nameRulePlacement, authorsNote, worldInfo, authoredText }

    init(from decoder: Decoder) throws {
        dialogueContent = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(DialogueContent.self, forKey: .dialogueContent)
        personaCore = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .personaCore)
        nameRulePlacement = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(NameRulePlacement.self, forKey: .nameRulePlacement)
        authorsNote = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(AuthorsNoteSettings.self, forKey: .authorsNote)
        worldInfo = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(WorldInfoSettings.self, forKey: .worldInfo)
        authoredText = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(DialogueTextSettings.self, forKey: .authoredText)
        persona = try PersonaResponseConfiguration(from: decoder)
        thinking = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(Bool.self, forKey: .thinking)
        sampling = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(EvaluationSampling.self, forKey: .sampling)
    }

    func snapshot() throws -> [String: Any] {
        var value = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(persona)
        ) as! [String: Any]
        if let dialogueContent { value["dialogueContent"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(dialogueContent)) }
        if let personaCore { value["personaCore"] = personaCore }
        if let thinking { value["thinking"] = thinking }
        if let sampling { value["sampling"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sampling)) }
        if let nameRulePlacement { value["nameRulePlacement"] = nameRulePlacement.rawValue }
        if let authorsNote { value["authorsNote"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(authorsNote)) }
        if let worldInfo { value["worldInfo"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(worldInfo)) }
        if let authoredText { value["authoredText"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(authoredText)) }
        return value
    }
}

private struct HistoryExchange: Decodable {
    let user: String
    let assistant: String
}

private struct RequestEnvelope: Decodable { let id: String; let operation: String }

private struct Request: Decodable {
    let id: String
    let operation: String
    let configuration: EvaluationConfiguration
    let retrievalDirectory: String?
    let characterName: String?
    let userMessage: String?
    let history: [HistoryExchange]?
    let memories: [String]?
    let insertions: [DialoguePromptInsertion]?
    let tokenBudget: DialogueTokenBudget?
    let measurerID: String?
    let worldInfoContext: WorldInfoContext?
    let worldInfoState: WorldInfoState?
    let worldInfoText: WorldInfoTextContext?
    let exampleDialogue: String?
    let sessionCheckpoint: DialogueSessionCheckpoint?
    let assistantMessage: String?
    let worldInfoTransaction: WorldInfoTransaction?
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
        if request.configuration.dialogueContent != nil && request.configuration.personaCore != nil {
            throw WorkerError.invalidRequest
        }
        if let content = request.configuration.dialogueContent, let name = request.characterName,
           content.name != name { throw WorkerError.invalidRequest }
        switch request.operation {
        case "validate":
            if request.configuration.persona.includePersona,
               (request.configuration.dialogueContent?.persona ?? request.configuration.personaCore)?
                   .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw RoutedPersonaPromptRegistryError.notConfigured
            }
            if let settings = request.configuration.worldInfo {
                let entries = settings.entries + (try settings.library?.entries(character: request.configuration.dialogueContent?.name ?? request.characterName ?? "엘레나") ?? [])
                try WorldInfoEngine.validate(.init(tokenBudget: settings.tokenBudget, entries: entries,
                    scanDepth: settings.scanDepth, rules: settings.rules))
            }
            return ["status": "valid"]
        case "prepare":
            guard let message = request.userMessage, !message.isEmpty else {
                throw WorkerError.invalidRequest
            }
            // Eval supplies recorded vector retrieval outputs; it must not silently
            // treat enabled semantic retrieval as an empty retrieval result.
            if request.configuration.worldInfo?.rules.vector != nil && request.worldInfoContext == nil {
                throw WorkerError.invalidRequest
            }
            let core = request.configuration.dialogueContent?.promptSet.core ?? request.configuration.personaCore
            if request.configuration.persona.includePersona,
               core?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw RoutedPersonaPromptRegistryError.notConfigured
            }
            let prompts = RoutedPersonaPromptSet(core: core ?? "")
            let profile = UserProfileContext(characterName: request.configuration.dialogueContent?.name ?? request.characterName ?? "엘레나")
            let generation = SLMConfiguration.production.generation
            let history = request.history ?? []
            var context = RoutedPersonaSessionContext(worldInfoState: request.worldInfoState ?? .init(), worldInfoText: request.worldInfoText ?? .init())
            if let checkpoint = request.sessionCheckpoint {
                guard history.isEmpty, request.worldInfoState == nil, request.worldInfoText == nil else { throw WorkerError.invalidRequest }
                context = try RoutedPersonaSessionContext(checkpoint: checkpoint)
            }
            for exchange in history {
                guard !exchange.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !exchange.assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw WorkerError.invalidRequest
                }
                context.appendExchange(userMessage: exchange.user, assistantMessage: exchange.assistant)
            }
            let memoryTexts = request.memories ?? []
            guard memoryTexts.count <= SLMConfiguration.production.memory.recallLimit,
                  memoryTexts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw WorkerError.invalidRequest
            }
            // These are fixed retrieval outputs; ranking is the fixture order.
            // Selection and budgeting remain owned by the shared Swift composer.
            let memories = memoryTexts.enumerated().map { index, text in
                RetrievedMemoryObservation(
                    observation: MemoryObservation(
                        id: "fixture-\(index)", turnID: "fixture-\(index)", sessionID: "fixture",
                        sequence: index, scope: MemoryScope(userID: "synthetic", characterID: "synthetic"),
                        occurredAt: Date(timeIntervalSince1970: 0), rawText: text,
                        labelEvidence: [MemoryLabelEvidence](), createdAt: Date(timeIntervalSince1970: 0)),
                    score: 1, rank: index)
            }
            let snapshot = try context.snapshot(requestID: request.id)
            var worldInfo = request.configuration.worldInfo
            var retrievalTrace = Data("{}".utf8)
            if let content = request.configuration.dialogueContent, content.retrieval != nil {
                guard let directory = request.retrievalDirectory else { throw WorkerError.invalidRequest }
                (worldInfo, retrievalTrace) = try await ReactionRetrieval.shared.prepare(directory: directory, content: content,
                    requestID: request.id, history: snapshot.history.map(\.text), message: message, base: worldInfo)
            }
            let input = DialoguePromptInput(persona: prompts, activeCard: prompts.card(scene: .general),
                profile: profile, history: snapshot.history, memories: memories, currentMessage: message,
                insertions: request.insertions ?? [], session: snapshot, authorsNote: request.configuration.authorsNote, worldInfo: worldInfo,
                worldInfoContext: request.worldInfoContext ?? .init(), exampleDialogue: request.configuration.dialogueContent?.exampleDialogue ?? request.exampleDialogue ?? "", authoredText: request.configuration.authoredText ?? .init())
            let policy = DialoguePromptPolicy(persona: request.configuration.persona,
                nameRulePlacement: request.configuration.nameRulePlacement ?? .system)
            let prepared: PreparedDialogue
            let outputTokens = request.tokenBudget?.outputTokens ?? SLMConfiguration.production.dialogueBudget.outputTokens
            if let budget = request.tokenBudget {
                guard let identifier = request.measurerID, !identifier.isEmpty else { throw WorkerError.invalidRequest }
                prepared = try await DialoguePromptComposer.prepare(input: input, policy: policy,
                    tokenBudget: budget, measurer: NativeTokenMeasurer(identifier: identifier, requestID: request.id,
                        thinking: request.configuration.thinking ?? generation.responseThinkingDefault,
                        outputTokens: outputTokens))
            } else {
                prepared = try DialoguePromptComposer.prepare(input: input, policy: policy)
            }
            return [
                "status": "prepared",
                "retrieval_trace": try JSONSerialization.jsonObject(with: retrievalTrace),
                "session_checkpoint": try JSONSerialization.jsonObject(with: JSONEncoder().encode(context.checkpoint())),
                "world_info_seed": DialogueSeedPolicy.worldInfo(base: request.worldInfoContext?.randomSeed ?? 1, completedMessages: context.completedMessages),
                "configuration": try request.configuration.snapshot(),
                // Role-grouped text remains diagnostic evidence for saved reports.
                "system_prompt": prepared.systemText,
                "user_prompt": prepared.userText,
                "model_input": try JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared.modelInput)),
                "unpositioned_user_prompt": prepared.unpositionedUserPrompt,
                "name_instruction": prepared.nameInstruction,
                "current_input": prepared.memoryAugmentedInput,
                "world_info_transaction": try prepared.worldInfoTransaction.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull(),
                "prompt_trace": try JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared.trace)),
                "input_format": "messages",
                "scope": memoryTexts.isEmpty ? "single-turn-fixed-general-empty-memory" : "single-turn-fixed-general-recalled-memory",
                "scene": "GENERAL", "recalled_memories": memoryTexts,
                "memory_stats": [
                    "retrieved_count": memoryTexts.count,
                    "inserted_count": prepared.trace.insertedMemoryCount,
                    "skipped_count": memoryTexts.count - prepared.trace.insertedMemoryCount,
                    "inserted_bytes": prepared.trace.insertedMemoryBytes,
                    "byte_budget": prepared.trace.memoryByteBudget as Any? ?? NSNull()
                ],
                "history": snapshot.history.map { ["role": $0.role.rawValue, "text": $0.text] },
                "history_stats": [
                    "injected_messages": context.visibleMessages,
                    "retained_messages": snapshot.history.count,
                    "dropped_messages": context.visibleMessages - snapshot.history.count,
                    "retained_turns": context.chatTurns.count,
                    "turn_limit": context.maximumTurnCount
                ],
                "session_clock": [
                    "completed_user_messages": snapshot.completedUserMessages,
                    "completed_messages": snapshot.completedMessages,
                    "current_user_message_number": snapshot.currentUserMessageNumber,
                    "current_message_number": snapshot.currentMessageNumber
                ],
                "memory_store": memoryTexts.isEmpty ? "disabled-fixture" : "fixed-retrieval-fixture",
                "sampling": [
                    "temperature": request.configuration.sampling?.temperature ?? Double(generation.responseSampling.temperature),
                    "top_k": request.configuration.sampling?.topK ?? generation.responseSampling.samplerTopK,
                    "top_p": request.configuration.sampling?.topP ?? Double(generation.responseSampling.topP),
                    "max_output_tokens": outputTokens,
                    "thinking": request.configuration.thinking ?? generation.responseThinkingDefault,
                    "filter_channel_content_from_kv_cache": true
                ]
            ]
        case "commit":
            guard let checkpoint = request.sessionCheckpoint, let user = request.userMessage,
                  let assistant = request.assistantMessage else { throw WorkerError.invalidRequest }
            var context = try RoutedPersonaSessionContext(checkpoint: checkpoint)
            // Transport call IDs vary on retry; the checkpoint must not vary with them.
            let pending = try context.snapshot(requestID: "evaluation-\(context.completedUserMessages + 1)")
            try context.commit(pending, userMessage: user, assistantMessage: assistant, worldInfo: request.worldInfoTransaction)
            return ["status": "committed", "session_checkpoint": try JSONSerialization.jsonObject(with: JSONEncoder().encode(context.checkpoint()))]
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
                let data = Data(line.utf8)
                // Keep the correlation ID even when nested settings fail validation.
                let envelope = try JSONDecoder().decode(RequestEnvelope.self, from: data)
                requestID = envelope.id
                if envelope.operation == "world-info" {
                    var result = try WorldInfoControl.handle(data)
                    result["id"] = envelope.id; result["protocol_version"] = 1
                    try emit(result)
                    continue
                }
                let request = try JSONDecoder().decode(Request.self, from: data)
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
