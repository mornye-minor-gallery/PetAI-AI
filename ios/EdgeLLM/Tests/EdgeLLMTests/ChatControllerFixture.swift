import Foundation
@testable import EdgeLLM

final class ChatEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NativeChatEvent] = []
    func receive(_ event: NativeChatEvent) { lock.withLock { events.append(event) } }
    func snapshot() -> [NativeChatEvent] { lock.withLock { events } }
}

struct ChatControllerFixture {
    let directory: URL
    let store: DialogueSessionFileStore
    let runtime = ChatTestRuntime()
    let memory = ChatTestMemory()
    let events = ChatEventRecorder()
    let controller: ChatSessionController

    init(toolRouterArtifacts: NativeToolRouterArtifactRegistry? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-controller-\(UUID())")
        store = .init(fileURL: directory.appendingPathComponent("recent.json"))
        controller = ChatSessionController(runtime: runtime, memory: memory,
            platform: ChatTestPlatform(store: store), eventSink: events.receive,
            toolRouterArtifacts: toolRouterArtifacts)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func request(_ id: String, _ text: String) -> String {
        let payload: [String: Any] = ["requestId": id, "prompt": text, "thinkingEnabled": false,
            "userProfileContext": ["characterId": "test", "userName": "", "rhythmGamePlayCount": 0,
                "rhythmGameBestScore": 0, "toolAccess": []]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }
}

actor ChatTestRuntime: ChatInferenceRuntime {
    var state: RuntimeState = .ready
    var generationCount = 0
    var diaryGenerationCount = 0
    var diaryFailure: Error?
    var checkpointCount = 0
    var holdStream = false
    var response = "save(P=0,E=0)\n반가워."
    var continuation: AsyncThrowingStream<String, Error>.Continuation?
    func setHolding(_ value: Bool) { holdStream = value }
    func setResponse(_ value: String) { response = value }
    func failDiary(with error: Error) { diaryFailure = error }
    func prepare(modelURL: URL) {}
    func startConversation(configuration: ConversationConfiguration) {}
    func prepareDialogue(input: DialoguePromptInput, policy: DialoguePromptPolicy,
                         thinkingEnabled: Bool) throws -> PreparedDialogue {
        try DialoguePromptComposer.prepare(input: input, policy: policy)
    }
    func generateStream(prompt: String) -> AsyncThrowingStream<String, Error> {
        generationCount += 1
        return AsyncThrowingStream {
            $0.yield(response)
            if holdStream { continuation = $0 } else { $0.finish() }
        }
    }
    func generateStream(prompt: String, thinkingEnabled: Bool) -> AsyncThrowingStream<String, Error> {
        generateStream(prompt: prompt)
    }
    func generateIsolated(systemPrompt: String, userMessage: String, sampling: SLMConfiguration.Sampling?,
                          thinkingEnabled: Bool?, maxOutputTokens: Int?) -> String { "" }
    func generateDiary(systemPrompt: String, userMessage: String) throws -> String {
        diaryGenerationCount += 1
        if let diaryFailure { throw diaryFailure }
        return "{\"title\":\"하루\",\"body\":\"쉬었어요.\"}"
    }
    func countDiaryInputTokens(systemPrompt: String, userMessage: String) -> Int { 100 }
    func generateFunctionCall(_ request: NativeToolGenerationRequest) throws -> NativeToolFunctionCall {
        throw RuntimeError.runtimeBusy
    }
    func cancel() { continuation?.finish(throwing: CancellationError()); continuation = nil }
    func resetConversation() {}
    func unload() {}
    func saveCompletedDialogueCheckpoint() { checkpointCount += 1 }
    func eraseCheckpoint() {}
}

actor ChatTestMemory: ChatMemoryService {
    nonisolated let modelID = "litert-community/embeddinggemma-300m-seq256-mixed-precision"
    nonisolated let dimension = 768
    var lastExcluded: Set<String> = []
    var holdWrite = false
    var writeStarted = false
    var closedDuringWrite = false
    var pendingWrite: CheckedContinuation<Void, Never>?
    var diaryObservations: [MemoryObservation] = []
    var savedDiaries: [String: DailyDiary] = [:]
    func setDiaryObservations(_ values: [MemoryObservation]) { diaryObservations = values }
    func holdWrites() { holdWrite = true }
    func finishWrite() { pendingWrite?.resume(); pendingWrite = nil }
    func prepare(modelURL: URL, tokenizerURL: URL) {}
    func close() { if pendingWrite != nil { closedDuringWrite = true } }
    func recall(_ request: MemorySearchRequest) -> [RetrievedMemoryObservation] {
        lastExcluded = request.excludedTurnIDs
        return []
    }
    func remember(_ request: MemoryWriteRequest, decision: MemoryGateDecision) async -> MemoryRememberResult {
        if holdWrite {
            writeStarted = true
            await withCheckedContinuation { pendingWrite = $0 }
        }
        return .ignoredEmpty
    }
    func searchEmbeddingIdentity() -> String { "test" }
    func embedClassification(_ text: String) -> [Float] { Array(repeating: 0, count: dimension) }
    func embedWorldInfoQuery(_ text: String) -> [Float] { Array(repeating: 0, count: dimension) }
    func searchWorldInfo(entries: [WorldInfoEntry], newestMessages: [String],
                         settings: WorldInfoVectorSettings) -> [WorldInfoVectorMatch] { [] }
    func allActiveObservations() -> [MemoryObservation] { [] }
    func activeObservations(in scope: MemoryScope, from start: Date, to end: Date) -> [MemoryObservation] {
        diaryObservations.filter { $0.scope == scope && $0.occurredAt >= start && $0.occurredAt < end }
    }
    func diary(characterID: String, localDate: String) -> DailyDiary? { savedDiaries[characterID + ":" + localDate] }
    func allDiaries() -> [DailyDiary] { Array(savedDiaries.values) }
    func insertDiaryIfAbsent(characterID: String, localDate: String, draft: DailyDiaryDraft) throws -> DailyDiary {
        let key = characterID + ":" + localDate
        if let existing = savedDiaries[key] { return existing }
        let value = DailyDiary(characterID: characterID, localDate: localDate, title: draft.title,
            body: draft.body, completedAt: Date())
        savedDiaries[key] = value
        return value
    }
    func eraseAllMemories() {}
}

struct ChatTestPlatform: ChatPlatformServices, ChatPlatformTools {
    let store: DialogueSessionFileStore
    var personaEnabled: Bool { true }
    var tools: any ChatPlatformTools { self }
    var supportedTools: Set<NativeToolKind> { [] }
    var unsupportedMessage: String { "Android에서는 준비 중인 기능입니다." }
    func enrich(_ base: UserProfileContext, allowedTools: Set<NativeToolKind>) -> UserProfileContext { base }
    func confirm(_ draft: NativeToolProposal) throws -> NativeToolProposal { throw NativeToolConfirmationError.cancelled }
    func cancelConfirmation() {}
    func execute(_ proposal: ValidatedToolProposal) throws -> JSONValue { throw NativeToolConfirmationError.unsupportedTool(proposal.tool) }
    func refreshModelAssets() {}
    func missingAsset() -> NativeAssetKind? { nil }
    func resolveModelAssets() -> RuntimeModelAssets {
        .init(languageModelURL: store.fileURL, embeddingModelURL: store.fileURL, tokenizerURL: store.fileURL, version: "test")
    }
    func selectAsset(_ kind: NativeAssetKind) throws -> URL { throw UnityBridgeError.modelSelectionCancelled }
    func importAsset(_ url: URL, kind: NativeAssetKind) {}
    func recentTurnStore() -> DialogueSessionFileStore { store }
    func loadContent() throws -> ChatContentResources {
        .init(content: try .load(data: Data(#"{"id":"test","name":"별","persona":"대화 시험용 캐릭터."}"#.utf8)))
    }
    func share(_ file: URL) {}
    func showExportError(_ message: String) {}
    func lockForTestReset() {}
    func resetTestData(removeModels: Bool) {}
}
