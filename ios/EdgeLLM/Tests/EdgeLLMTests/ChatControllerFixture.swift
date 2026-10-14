import Foundation
@testable import EdgeLLM

final class ChatEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NativeChatEvent] = []
    private var receiver: (@Sendable (NativeChatEvent) -> Void)?
    func setReceiver(_ receiver: @escaping @Sendable (NativeChatEvent) -> Void) {
        lock.withLock { self.receiver = receiver }
    }
    func receive(_ event: NativeChatEvent) {
        let receiver = lock.withLock { events.append(event); return self.receiver }
        receiver?(event)
    }
    func snapshot() -> [NativeChatEvent] { lock.withLock { events } }
}

struct ChatControllerFixture {
    let directory: URL
    let store: DialogueSessionFileStore
    let runtime = ChatTestRuntime()
    let memory = ChatTestMemory()
    let events = ChatEventRecorder()
    let controller: ChatSessionController

    init(automaticallyFinalize: Bool = true, tools: (any ChatPlatformTools)? = nil,
         configuration: SLMConfiguration = .production,
         personaEnabled: Bool = true,
         log: @escaping @Sendable (String) -> Void = { _ in },
         toolRouterArtifacts: NativeToolRouterArtifactRegistry? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-controller-\(UUID())")
        store = .init(fileURL: directory.appendingPathComponent("recent.json"))
        controller = ChatSessionController(configuration: configuration, runtime: runtime, memory: memory,
            platform: ChatTestPlatform(store: store, toolAdapter: tools, personaEnabled: personaEnabled), eventSink: events.receive, log: log,
            toolRouterArtifacts: toolRouterArtifacts)
        if automaticallyFinalize {
            let controller = controller
            // Existing controller tests use a display host that accepts every delivered token.
            events.setReceiver { [weak controller] event in
                guard event.type == "completion_pending" || event.type == "cancellation_pending",
                      let id = event.requestId, let controller else { return }
                let decision = NativeTurnDecision(requestId: id,
                    cancelled: event.type == "cancellation_pending", text: event.text ?? "")
                let json = String(decoding: try! JSONEncoder().encode(decision), as: UTF8.self)
                Task { await controller.finalizeTurn(json: json) }
            }
        }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func request(_ id: String, _ text: String, allowedTools: [NativeToolKind] = []) -> String {
        let access = allowedTools.map { ["tool": $0.rawValue, "unlockSource": "test", "unlocked": true] as [String: Any] }
        let payload: [String: Any] = ["requestId": id, "prompt": text, "thinkingEnabled": false,
            "userProfileContext": ["characterId": "test", "userName": "", "roomPlacementCount": 0, "toolAccess": access]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }
}

actor ChatTestRuntime: ChatInferenceRuntime {
    nonisolated let identifier = "synthetic-chat-tokenizer"
    var state: RuntimeState = .ready
    var generationCount = 0
    var functionCallCount = 0
    var functionCall: NativeToolFunctionCall?
    var diaryGenerationCount = 0
    var diaryFailure: Error?
    var checkpointCount = 0
    var checkpointFailure: Error?
    var summaryGenerationCount = 0
    var summaryInput = ""
    var summaryResponse = "짧게 정리한 대화입니다."
    var summaryFailure: Error?
    var prefillFailure: Error?
    var preparationBudget: DialogueTokenBudget?
    var preparationFailure: Error?
    var prefillStarted = false
    var holdPrefill = false
    private var prefillWaiter: CheckedContinuation<Void, Never>?
    private var prefillContinuation: CheckedContinuation<Void, Never>?
    var prefilledInputs: [DialogueModelInput] = []
    var lastPreparedHistory: [RoutedPersonaSessionContext.Turn] = []
    var holdStream = false
    var response = "save(P=0,E=0)\n반가워."
    var continuation: AsyncThrowingStream<String, Error>.Continuation?
    func setHolding(_ value: Bool) { holdStream = value }
    func setResponse(_ value: String) { response = value }
    func setFunctionCall(_ value: NativeToolFunctionCall) { functionCall = value }
    func failDiary(with error: Error) { diaryFailure = error }
    func failCheckpoint(with error: Error) { checkpointFailure = error }
    func failSummary(with error: Error) { summaryFailure = error }
    func failPrefill(with error: Error) { prefillFailure = error }
    func failPreparation(with error: Error) { preparationFailure = error }
    func usePreparationBudget(_ budget: DialogueTokenBudget) { preparationBudget = budget }
    func holdPrefills() { holdPrefill = true }
    func waitForPrefill() async {
        if prefillStarted { return }
        await withCheckedContinuation { prefillWaiter = $0 }
    }
    func finishPrefill() { prefillContinuation?.resume(); prefillContinuation = nil; holdPrefill = false }
    func setSummary(_ text: String) { summaryResponse = text }
    func prepare(modelURL: URL) {}
    func startConversation(configuration: ConversationConfiguration) {}
    func prepareDialogue(input: DialoguePromptInput, policy: DialoguePromptPolicy,
                         thinkingEnabled: Bool) async throws -> PreparedDialogue {
        if let preparationFailure { throw preparationFailure }
        lastPreparedHistory = input.history
        if let preparationBudget {
            return try await DialoguePromptComposer.prepare(input: input, policy: policy,
                tokenBudget: preparationBudget, measurer: self, allowContextOverflow: true)
        }
        return try DialoguePromptComposer.prepare(input: input, policy: policy)
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
        functionCallCount += 1
        guard let functionCall else { throw RuntimeError.runtimeBusy }
        return functionCall
    }
    func cancel() { continuation?.finish(throwing: CancellationError()); continuation = nil }
    func resetConversation() {}
    func unload() {}
    func saveCompletedDialogueCheckpoint() throws {
        checkpointCount += 1
        if let checkpointFailure { throw checkpointFailure }
    }
    func eraseCheckpoint() {}
    func countTokens(_ text: String) -> Int { text.count }
    func measureInput(_ input: DialogueModelInput) -> Int {
        input.messages.reduce(17) { $0 + $1.text.count + 7 }
    }
    func generateDialogueSummary(_ text: String, maximumTokens: Int) throws -> String {
        summaryGenerationCount += 1; summaryInput = text
        if let summaryFailure { throw summaryFailure }
        return summaryResponse
    }
    func prefillDialogueContext(_ input: DialogueModelInput, thinkingEnabled: Bool) async throws {
        if let prefillFailure { throw prefillFailure }
        prefillStarted = true
        prefillWaiter?.resume(); prefillWaiter = nil
        if holdPrefill { await withCheckedContinuation { prefillContinuation = $0 } }
        prefilledInputs.append(input)
    }
}

actor ChatTestMemory: ChatMemoryService {
    nonisolated let modelID = "litert-community/embeddinggemma-300m-seq256-mixed-precision"
    nonisolated let dimension = 768
    var lastExcluded: Set<String> = []
    var holdWrite = false
    var writeStarted = false
    var writeCount = 0
    var closedDuringWrite = false
    var pendingWrite: CheckedContinuation<Void, Never>?
    var diaryObservations: [MemoryObservation] = []
    var savedDiaries: [String: DailyDiary] = [:]
    var classificationEmbedding = Array(repeating: Float(0), count: 768)
    var classificationCount = 0
    var classificationError: Error?
    func setClassificationEmbedding(_ value: [Float]) { classificationEmbedding = value }
    func failClassification(with error: Error) { classificationError = error }
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
        writeCount += 1
        if holdWrite {
            writeStarted = true
            await withCheckedContinuation { pendingWrite = $0 }
        }
        return .ignoredEmpty
    }
    func searchEmbeddingIdentity() -> String { "test" }
    func embedClassification(_ text: String) throws -> [Float] {
        classificationCount += 1
        if let classificationError { throw classificationError }
        return classificationEmbedding
    }
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
    var toolAdapter: (any ChatPlatformTools)? = nil
    var personaEnabled = true
    var tools: any ChatPlatformTools { toolAdapter ?? self }
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
