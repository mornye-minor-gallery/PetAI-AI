import Foundation
import Testing
@testable import EdgeLLM

private actor RecordingMemoryStore: MemoryObservationStoring {
    nonisolated let securityPolicy: MemoryStoreSecurityPolicy

    private var didInitialize = false
    private var observations: [MemoryObservation] = []
    private var deletedObservationIDs: [String] = []
    private var deletedObservationScopes: [MemoryScope] = []

    init(
        securityPolicy: MemoryStoreSecurityPolicy =
            .encryptedOnDeviceOnly
    ) {
        self.securityPolicy = securityPolicy
    }

    func initialize() async throws {
        didInitialize = true
    }

    func save(_ observation: MemoryObservation) async throws {
        observations.append(observation)
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
        in scope: MemoryScope,
        updatedAt: Date
    ) async throws {
        deletedObservationIDs.append(observationID)
        deletedObservationScopes.append(scope)
    }

    func close() async {}

    func snapshot() -> (
        initialized: Bool,
        observations: [MemoryObservation],
        deletedObservationIDs: [String],
        deletedObservationScopes: [MemoryScope]
    ) {
        (
            didInitialize,
            observations,
            deletedObservationIDs,
            deletedObservationScopes
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
    private var initializationStartWaiters: [
        CheckedContinuation<Void, Never>
    ] = []
    private var initializationContinuation:
        CheckedContinuation<Void, Never>?

    func initialize() async throws {
        initializationStarted = true
        let waiters = initializationStartWaiters
        initializationStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            initializationContinuation = continuation
        }
    }

    func save(_ observation: MemoryObservation) async throws {}

    func activeObservations(
        in scope: MemoryScope
    ) async throws -> [MemoryObservation] {
        []
    }

    func markDeleted(
        observationID: String,
        in scope: MemoryScope,
        updatedAt: Date
    ) async throws {}

    func close() async {}

    func waitUntilInitializationStarts() async {
        guard !initializationStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            initializationStartWaiters.append(continuation)
        }
    }

    func resumeInitialization() {
        initializationContinuation?.resume()
        initializationContinuation = nil
    }
}

@Test
func naiveClassifierFindsPreferenceAndEventWithoutGeneralMessages() async throws {
    let classifier = NaivePreferenceEventClassifier()

    #expect(
        try await classifier.classify("나는 포도를 좋아해")
            == [.preference]
    )
    #expect(
        try await classifier.classify("어제 미술관에 다녀왔어")
            == [.event]
    )
    #expect(
        try await classifier.classify(
            "나는 포도를 좋아하고 어제 행사에도 다녀왔어"
        ) == [.preference, .event]
    )
    #expect(try await classifier.classify("오늘 뭐 할까?").isEmpty)
}

@Test
func memoryEngineStoresOnlyPreferenceOrEventForTheCharacterScope() async throws {
    let store = RecordingMemoryStore()
    let timestamp = Date(timeIntervalSince1970: 1_721_280_000)
    let engine = MemoryEngine(
        store: store,
        makeObservationID: { "observation-1" },
        now: { timestamp }
    )
    let scope = MemoryScope(userID: "local-user", characterID: "emu")

    try await engine.prepare()

    let ignored = try await engine.remember(
        MemoryWriteRequest(
            sourceMessageID: "message-1",
            sessionID: "session-1",
            scope: scope,
            rawText: "오늘 뭐 할까?",
            occurredAt: timestamp
        )
    )
    #expect(ignored == .ignored(.notPreferenceOrEvent))

    let stored = try await engine.remember(
        MemoryWriteRequest(
            sourceMessageID: "message-2",
            sessionID: "session-1",
            scope: scope,
            rawText: "  나는 포도를 좋아해  ",
            occurredAt: timestamp
        )
    )

    guard case let .stored(observation) = stored else {
        Issue.record("Expected a stored preference observation.")
        return
    }
    #expect(observation.id == "observation-1")
    #expect(observation.scope == scope)
    #expect(observation.rawText == "  나는 포도를 좋아해  ")
    #expect(observation.labels == [.preference])

    let snapshot = await store.snapshot()
    #expect(snapshot.initialized)
    #expect(snapshot.observations == [observation])
}

@Test
func memoryEngineRejectsAStoreWithoutTheRequiredSecurityPolicy() async {
    let insecurePolicy = MemoryStoreSecurityPolicy(
        requiresDatabaseEncryption: false,
        applicationSandboxOnly: true,
        excludedFromCloudBackup: true
    )
    let store = RecordingMemoryStore(securityPolicy: insecurePolicy)
    let engine = MemoryEngine(store: store)

    await #expect(throws: MemoryEngineError.insecureStoreConfiguration) {
        try await engine.prepare()
    }
}

@Test
func memoryEngineBlocksStoreAccessUntilPreparedAndAfterClose() async throws {
    let store = RecordingMemoryStore()
    let engine = MemoryEngine(store: store)
    let scope = MemoryScope(userID: "local-user", characterID: "emu")
    let request = MemoryWriteRequest(
        sourceMessageID: "message-1",
        sessionID: "session-1",
        scope: scope,
        rawText: "나는 포도를 좋아해",
        occurredAt: Date(timeIntervalSince1970: 1_721_280_000)
    )

    await #expect(throws: MemoryEngineError.notPrepared) {
        try await engine.remember(request)
    }
    await #expect(throws: MemoryEngineError.notPrepared) {
        try await engine.activeObservations(in: scope)
    }
    await #expect(throws: MemoryEngineError.notPrepared) {
        try await engine.deleteObservation(
            observationID: "observation-1",
            in: scope
        )
    }

    try await engine.prepare()
    await engine.close()

    await #expect(throws: MemoryEngineError.notPrepared) {
        try await engine.activeObservations(in: scope)
    }
    #expect((await store.snapshot()).observations.isEmpty)
}

@Test
func initializedPlainStoreCannotBypassEncryptedEngineRequirement() async throws {
    let store = RecordingMemoryStore(securityPolicy: .appPrivatePrototype)
    let engine = MemoryEngine(store: store)
    let request = MemoryWriteRequest(
        sourceMessageID: "message-1",
        sessionID: "session-1",
        scope: MemoryScope(userID: "local-user", characterID: "emu"),
        rawText: "나는 포도를 좋아해",
        occurredAt: Date(timeIntervalSince1970: 1_721_280_000)
    )

    try await store.initialize()

    await #expect(throws: MemoryEngineError.notPrepared) {
        try await engine.remember(request)
    }
    #expect((await store.snapshot()).observations.isEmpty)
}

@Test
func closeInvalidatesSuspendedPrepareContinuation() async {
    let store = SuspendingInitializationMemoryStore()
    let engine = MemoryEngine(store: store)
    let scope = MemoryScope(userID: "local-user", characterID: "emu")
    let prepareTask = Task {
        try await engine.prepare()
    }

    await store.waitUntilInitializationStarts()
    await engine.close()
    await store.resumeInitialization()

    await #expect(throws: MemoryEngineError.notPrepared) {
        try await prepareTask.value
    }
    await #expect(throws: MemoryEngineError.notPrepared) {
        try await engine.activeObservations(in: scope)
    }
}

@Test
func retrievalFailureIsLoggedAndReturnsNoMemory() async {
    let store = RecordingMemoryStore()
    let diagnostics = RecordingMemoryDiagnostics()
    let engine = MemoryEngine(
        store: store,
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
func sqliteSchemaContainsTheRawObservationAndDenseIndexContracts() {
    let schema = EdgeMemSQLiteSchema.statements.joined(separator: "\n")

    #expect(EdgeMemSQLiteSchema.version == 1)
    #expect(schema.contains("source_message_id"))
    #expect(schema.contains("character_id"))
    #expect(schema.contains("raw_text"))
    #expect(schema.contains("supersedes_observation_id"))
    #expect(schema.contains("memory_observation_labels"))
    #expect(schema.contains("memory_observation_embeddings"))
    #expect(schema.contains("CHECK (label IN ('preference', 'event'))"))
    #expect(!schema.lowercased().contains("fts5"))
}
