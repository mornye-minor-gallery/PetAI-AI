import Foundation
import Testing
@testable import EdgeLLM

private struct FixedMemoryClassifier: MemoryObservationClassifying {
    let decision: MemoryGateDecision
    var version: String {
        decision.classifierVersion
    }

    func evaluate(_ text: String) async throws -> MemoryGateDecision {
        decision
    }
}

private struct FailingMemoryClassifier: MemoryObservationClassifying {
    struct UnexpectedEvaluation: Error {}

    let version = "must-not-run"

    func evaluate(_ text: String) async throws -> MemoryGateDecision {
        throw UnexpectedEvaluation()
    }
}

private func gateDecision(
    _ label: MemoryGateLabel,
    hardIgnore: Bool = false
) -> MemoryGateDecision {
    MemoryGateDecision(
        label: label,
        regex: MemoryRegexGateResult(
            preferenceHit: label == .preference || label == .both,
            eventHit: label == .event || label == .both,
            hardIgnore: hardIgnore
        ),
        preferenceScore: nil,
        eventScore: nil,
        preferenceThreshold: 0.08,
        eventThreshold: 0.08,
        classifierVersion: "test-gate-v1",
        embeddingModelID: nil
    )
}

private actor RecordingMemoryStore: MemoryObservationStoring {
    nonisolated let securityPolicy: MemoryStoreSecurityPolicy

    private var didInitialize = false
    private var turns: [MemoryConversationTurn] = []
    private var gates: [MemoryGateResult] = []
    private var observations: [MemoryObservation] = []
    private var embeddings: [MemoryObservationEmbedding?] = []
    private var deletedObservationIDs: [String] = []

    init(
        securityPolicy: MemoryStoreSecurityPolicy =
            .encryptedOnDeviceOnly
    ) {
        self.securityPolicy = securityPolicy
    }

    func initialize() async throws {
        didInitialize = true
    }

    func saveUserTurn(
        id: String,
        sessionID: String,
        scope: MemoryScope,
        rawText: String,
        occurredAt: Date
    ) async throws -> MemoryConversationTurn {
        let turn = MemoryConversationTurn(
            id: id,
            sessionID: sessionID,
            sequence: turns.filter { $0.sessionID == sessionID }.count,
            scope: scope,
            rawText: rawText,
            occurredAt: occurredAt,
            contentHash: "test-hash"
        )
        turns.append(turn)
        return turn
    }

    func saveGateResult(_ result: MemoryGateResult) async throws {
        gates.append(result)
    }

    func saveObservation(
        _ observation: MemoryObservation,
        embedding: MemoryObservationEmbedding?
    ) async throws {
        observations.append(observation)
        embeddings.append(embedding)
    }

    func activeObservations(
        in scope: MemoryScope
    ) async throws -> [MemoryObservation] {
        observations.filter {
            $0.scope == scope && $0.state == .active
        }
    }

    func markDeleted(
        observationID: String,
        in scope: MemoryScope
    ) async throws {
        deletedObservationIDs.append(observationID)
    }

    func close() async {}

    func snapshot() -> (
        initialized: Bool,
        turns: [MemoryConversationTurn],
        gates: [MemoryGateResult],
        observations: [MemoryObservation],
        embeddings: [MemoryObservationEmbedding?],
        deletedObservationIDs: [String]
    ) {
        (
            didInitialize,
            turns,
            gates,
            observations,
            embeddings,
            deletedObservationIDs
        )
    }
}

private struct FailingMemoryRetriever: MemoryRetrieving {
    struct SearchFailure: Error {}

    func search(
        _ request: MemorySearchRequest
    ) async throws -> [RetrievedMemoryObservation] {
        throw SearchFailure()
    }
}

private struct MemoryEngineTestEmbedder: TextEmbeddingProviding {
    let modelID = "test-embedding-v1"
    let dimension = 3

    func embedQuery(_ text: String) async throws -> [Float] {
        [0, 1, 0]
    }

    func embedDocument(_ text: String) async throws -> [Float] {
        [1, 0, 0]
    }
}

private struct ClassifierTestEmbedder:
    ClassificationEmbeddingProviding
{
    let modelID = "classification-test-v1"
    let dimension = 3

    func embedClassification(_ text: String) async throws -> [Float] {
        if text.contains("좋아") || text.contains("딸기") {
            return [1, 0, 0]
        }
        if text.contains("다녀") || text.contains("미술관") {
            return [0, 1, 0]
        }
        return [0, 0, 1]
    }
}

private actor RecordingMemoryDiagnostics: MemoryDiagnostics {
    private var messages: [String] = []

    func logSearchFailure(_ message: String) async {
        messages.append(message)
    }

    func recordedMessages() -> [String] {
        messages
    }
}

private actor SuspendingInitializationMemoryStore:
    MemoryObservationStoring
{
    nonisolated let securityPolicy: MemoryStoreSecurityPolicy =
        .encryptedOnDeviceOnly

    private var initializationStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var initializationContinuation:
        CheckedContinuation<Void, Never>?

    func initialize() async throws {
        initializationStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            initializationContinuation = continuation
        }
    }

    func saveUserTurn(
        id: String,
        sessionID: String,
        scope: MemoryScope,
        rawText: String,
        occurredAt: Date
    ) async throws -> MemoryConversationTurn {
        Issue.record("Unexpected store access.")
        throw MemoryEngineError.notPrepared
    }

    func saveGateResult(_ result: MemoryGateResult) async throws {}

    func saveObservation(
        _ observation: MemoryObservation,
        embedding: MemoryObservationEmbedding?
    ) async throws {}

    func activeObservations(
        in scope: MemoryScope
    ) async throws -> [MemoryObservation] {
        []
    }

    func markDeleted(
        observationID: String,
        in scope: MemoryScope
    ) async throws {}

    func close() async {}

    func waitUntilInitializationStarts() async {
        guard !initializationStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeInitialization() {
        initializationContinuation?.resume()
        initializationContinuation = nil
    }
}

@Test
func koreanRegexGateMatchesEdgeMemSignalsAndOnlyHardIgnoresSmallTalk() {
    let gate = KoreanObservationRegexGate()

    #expect(gate.evaluate("나는 포도를 좋아해").preferenceHit)
    #expect(gate.evaluate("어제 미술관에 다녀왔어").eventHit)
    #expect(gate.evaluate("오늘 날씨가 어때?").eventHit == false)
    #expect(gate.evaluate("내가 좋아하는 과일 기억나?").hardIgnore == false)
    #expect(gate.evaluate("안녕").hardIgnore)
}

@Test
func prototypeClassifierProducesPreferenceEventAndNoneDecisions() async throws {
    let prototypes = try MemoryPrototypeSet(
        schemaVersion: 1,
        preference: ["나는 과일을 좋아해"],
        event: ["어제 미술관에 다녀왔어"],
        none: ["다시 설명해줘"],
        sourceSHA256: String(repeating: "a", count: 64)
    )
    let classifier = RegexPrototypeObservationClassifier(
        embedder: ClassifierTestEmbedder(),
        prototypes: prototypes
    )

    #expect(
        try await classifier.evaluate("딸기가 마음에 들어").label
            == .preference
    )
    #expect(
        try await classifier.evaluate("미술관을 방문했어").label
            == .event
    )
    #expect(
        try await classifier.evaluate("코드를 설명해줘").label
            == .none
    )
}

@Test
func koreanPrototypeResourceMatchesTheCanonicalEdgeMemSource() throws {
    let prototypes = try MemoryPrototypeSet.korean()

    #expect(prototypes.schemaVersion == 1)
    #expect(prototypes.preference.count == 12)
    #expect(prototypes.event.count == 12)
    #expect(prototypes.none.count == 12)
    #expect(
        prototypes.sourceSHA256
            == "54c7454eee3e678b22895ec220689c863e3711940cedf60a25113bad4e29cc76"
    )
}

@Test
func memoryEngineSkipsObservationWhenClassifierReturnsNone() async throws {
    let store = RecordingMemoryStore()
    let timestamp = Date(timeIntervalSince1970: 1_721_280_000)
    let engine = MemoryEngine(
        store: store,
        classifier: FixedMemoryClassifier(decision: gateDecision(.none)),
        makeObservationID: { "observation-1" },
        makeGateResultID: { "gate-1" },
        now: { timestamp }
    )
    let scope = MemoryScope(userID: "local-user", characterID: "emu")
    try await engine.prepare()

    let result = try await engine.remember(
        MemoryWriteRequest(
            sourceMessageID: "message-1",
            sessionID: "session-1",
            scope: scope,
            rawText: "오늘 뭐 할까?",
            occurredAt: timestamp
        )
    )

    #expect(result.status == .skippedNoMemorySignal)
    #expect(result.observation == nil)
    let snapshot = await store.snapshot()
    #expect(snapshot.turns.count == 1)
    #expect(snapshot.gates.count == 1)
    #expect(snapshot.observations.isEmpty)
    #expect(snapshot.embeddings.isEmpty)
}

@Test
func memoryEngineHardIgnoreKeepsTurnAndGateWithoutObservation() async throws {
    let store = RecordingMemoryStore()
    let decision = gateDecision(.none, hardIgnore: true)
    let engine = MemoryEngine(
        store: store,
        classifier: FixedMemoryClassifier(decision: decision)
    )
    try await engine.prepare()

    let result = try await engine.remember(
        MemoryWriteRequest(
            sourceMessageID: "message-1",
            sessionID: "session-1",
            scope: MemoryScope(
                userID: "local-user",
                characterID: "emu"
            ),
            rawText: "안녕"
        )
    )

    #expect(result.status == .skippedHardIgnore)
    let snapshot = await store.snapshot()
    #expect(snapshot.turns.count == 1)
    #expect(snapshot.gates.count == 1)
    #expect(snapshot.observations.isEmpty)
}

@Test
func memoryEngineStoresBothLabelsOnOneObservation() async throws {
    let store = RecordingMemoryStore()
    let engine = MemoryEngine(
        store: store,
        classifier: FixedMemoryClassifier(decision: gateDecision(.both)),
        makeObservationID: { "observation-1" }
    )
    try await engine.prepare()

    let result = try await engine.remember(
        MemoryWriteRequest(
            sourceMessageID: "message-1",
            sessionID: "session-1",
            scope: MemoryScope(
                userID: "local-user",
                characterID: "emu"
            ),
            rawText: "나는 미술관을 좋아하고 어제 다녀왔어"
        )
    )

    #expect(result.status == .indexed)
    #expect(result.observation?.labels == [.event, .preference])
    #expect((await store.snapshot()).observations.count == 1)
}

@Test
func taggedChatDecisionBypassesTheConfiguredClassifier() async throws {
    let store = RecordingMemoryStore()
    let engine = MemoryEngine(
        store: store,
        classifier: FailingMemoryClassifier(),
        makeObservationID: { "observation-header" }
    )
    try await engine.prepare()

    let result = try await engine.remember(
        MemoryWriteRequest(
            sourceMessageID: "message-header",
            sessionID: "session-1",
            scope: MemoryScope(
                userID: "local-user",
                characterID: "emu"
            ),
            rawText: "어제 떡볶이를 먹었는데 완전 내 취향이야"
        ),
        decision: .taggedChat(.both)
    )

    #expect(result.status == .indexed)
    #expect(result.observation?.labels == [.event, .preference])
    #expect(
        result.observation?.labelEvidence.allSatisfy {
            $0.source == .gemmaHeader
        } == true
    )
}

@Test
func memoryEngineStoresObservationAndDocumentEmbeddingTogether() async throws {
    let store = RecordingMemoryStore()
    let timestamp = Date(timeIntervalSince1970: 1_721_280_000)
    let engine = MemoryEngine(
        store: store,
        classifier: FixedMemoryClassifier(
            decision: gateDecision(.preference)
        ),
        embedder: MemoryEngineTestEmbedder(),
        makeObservationID: { "observation-embedded" },
        now: { timestamp }
    )
    try await engine.prepare()

    let result = try await engine.remember(
        MemoryWriteRequest(
            sourceMessageID: "message-1",
            sessionID: "session-1",
            scope: MemoryScope(
                userID: "local-user",
                characterID: "emu"
            ),
            rawText: "나는 포도를 좋아해",
            occurredAt: timestamp
        )
    )

    #expect(result.status == .indexed)
    #expect(
        (await store.snapshot()).embeddings == [
            MemoryObservationEmbedding(
                observationID: "observation-embedded",
                modelID: "test-embedding-v1",
                vector: [1, 0, 0],
                createdAt: timestamp
            )
        ]
    )
}

@Test
func memoryEngineRejectsStoreWithoutRequiredSecurityPolicy() async {
    let store = RecordingMemoryStore(
        securityPolicy: .appPrivatePrototype
    )
    let engine = MemoryEngine(
        store: store,
        classifier: FixedMemoryClassifier(decision: gateDecision(.none))
    )

    await #expect(throws: MemoryEngineError.insecureStoreConfiguration) {
        try await engine.prepare()
    }
}

@Test
func memoryEngineBlocksStoreAccessUntilPreparedAndAfterClose() async throws {
    let store = RecordingMemoryStore()
    let engine = MemoryEngine(
        store: store,
        classifier: FixedMemoryClassifier(decision: gateDecision(.none))
    )
    let scope = MemoryScope(userID: "local-user", characterID: "emu")

    await #expect(throws: MemoryEngineError.notPrepared) {
        try await engine.activeObservations(in: scope)
    }
    try await engine.prepare()
    await engine.close()
    await #expect(throws: MemoryEngineError.notPrepared) {
        try await engine.activeObservations(in: scope)
    }
}

@Test
func closeInvalidatesSuspendedPrepareContinuation() async {
    let store = SuspendingInitializationMemoryStore()
    let engine = MemoryEngine(
        store: store,
        classifier: FixedMemoryClassifier(decision: gateDecision(.none))
    )
    let prepareTask = Task {
        try await engine.prepare()
    }

    await store.waitUntilInitializationStarts()
    await engine.close()
    await store.resumeInitialization()

    await #expect(throws: MemoryEngineError.notPrepared) {
        try await prepareTask.value
    }
}

@Test
func retrievalFailureIsLoggedAndReturnsNoMemory() async {
    let store = RecordingMemoryStore()
    let diagnostics = RecordingMemoryDiagnostics()
    let engine = MemoryEngine(
        store: store,
        classifier: FixedMemoryClassifier(decision: gateDecision(.none)),
        retriever: FailingMemoryRetriever(),
        diagnostics: diagnostics
    )

    let results = await engine.recall(
        MemorySearchRequest(
            scope: MemoryScope(
                userID: "local-user",
                characterID: "emu"
            ),
            query: "내가 좋아하는 과일이 뭐였지?"
        )
    )

    #expect(results.isEmpty)
    #expect(await diagnostics.recordedMessages().count == 1)
}

@Test
func sqliteSchemaIsTheFirstCanonicalObservationMemoryContract() {
    let schema = EdgeMemSQLiteSchema.statements.joined(separator: "\n")

    #expect(EdgeMemSQLiteSchema.version == 2)
    #expect(schema.contains("conversation_turns"))
    #expect(schema.contains("gate_results"))
    #expect(schema.contains("observations"))
    #expect(schema.contains("observation_labels"))
    #expect(schema.contains("observation_embeddings"))
    #expect(schema.contains("content_hash"))
    #expect(schema.contains("gemma_header"))
    #expect(schema.contains("CHECK (decision IN"))
    #expect(!schema.contains("memory_observations"))
    #expect(!schema.lowercased().contains("fts5"))
}
