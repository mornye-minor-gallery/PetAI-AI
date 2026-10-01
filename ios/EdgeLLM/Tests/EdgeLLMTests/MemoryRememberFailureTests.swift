import Foundation
import SQLite3
import Testing
@testable import EdgeLLM

enum RememberFailureStage: String, CaseIterable, Sendable {
    case classification
    case embedding
    case observationInsert
    case turnInsert, gateInsert, labelInsert, embeddingInsert, commit, automaticRollback, rollbackFailure
}

private enum InjectedRememberFailure: Error {
    case classification
    case embedding
}

private enum FailureTestDatabaseError: Error {
    case open
    case statement
}

private struct ThrowingMemoryClassifier: MemoryObservationClassifying {
    let version = "failure-test-v1"

    func evaluate(_ text: String) async throws -> MemoryGateDecision {
        throw InjectedRememberFailure.classification
    }
}

private struct ThrowingMemoryEmbedder: TextEmbeddingProviding {
    let modelID = "failure-test-embedding-v1"
    let dimension = 3

    func embedQuery(_ text: String) async throws -> [Float] {
        throw InjectedRememberFailure.embedding
    }

    func embedDocument(_ text: String) async throws -> [Float] {
        throw InjectedRememberFailure.embedding
    }
}

private struct WorkingMemoryEmbedder: TextEmbeddingProviding {
    let modelID = "failure-test-embedding-v1"
    let dimension = 3
    func embedQuery(_ text: String) async throws -> [Float] { [1, 0, 0] }
    func embedDocument(_ text: String) async throws -> [Float] { [1, 0, 0] }
}

extension SQLiteObservationStore {
    fileprivate func denyRollbackForTest() throws {
        try withStatement("SELECT 1;") { statement in
            sqlite3_set_authorizer(sqlite3_db_handle(statement), { _, action, first, _, _, _ in
                if action == SQLITE_TRANSACTION, let first,
                   String(cString: first) == "ROLLBACK" {
                    return SQLITE_DENY
                }
                return SQLITE_OK
            }, nil)
        }
    }
}

private func preferenceDecision() -> MemoryGateDecision {
    MemoryGateDecision(
        label: .preference,
        regex: MemoryRegexGateResult(preferenceHit: true, eventHit: false),
        preferenceScore: nil,
        eventScore: nil,
        preferenceThreshold: 0.08,
        eventThreshold: 0.08,
        classifierVersion: "failure-test-v1",
        embeddingModelID: nil
    )
}

private actor SuspendedMemoryEmbedder: TextEmbeddingProviding {
    nonisolated let modelID = "suspended-test"
    nonisolated let dimension = 3
    private var continuation: CheckedContinuation<[Float], Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func embedQuery(_ text: String) async throws -> [Float] { [1, 0, 0] }
    func embedDocument(_ text: String) async throws -> [Float] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resume() {
        continuation?.resume(returning: [1, 0, 0])
        continuation = nil
    }
}

@Test(arguments: [false, true])
func interruptedCalculationDoesNotWriteMemory(reopen: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteObservationStore(databaseURL: directory.appendingPathComponent("memory.sqlite3"))
    let embedder = SuspendedMemoryEmbedder()
    let engine = MemoryEngine(store: store, classifier: ThrowingMemoryClassifier(), embedder: embedder,
                              securityRequirement: .allowsUnencryptedAppPrivatePrototype)
    try await engine.prepare()
    let scope = MemoryScope(userID: "test-user", characterID: "test-character")
    let request = MemoryWriteRequest(sourceMessageID: "cancelled", sessionID: "session-1",
                                    scope: scope, rawText: "나는 포도를 좋아해")
    let task = Task { try await engine.remember(request, decision: preferenceDecision()) }
    await embedder.waitUntilStarted()
    if reopen {
        await engine.close()
        try await engine.prepare()
    } else {
        task.cancel()
    }
    await embedder.resume()
    if reopen {
        await #expect(throws: MemoryEngineError.notPrepared) { try await task.value }
    } else {
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    #expect(try await store.activeObservations(in: scope).isEmpty)
    await engine.close()
    for table in ["conversation_turns", "gate_results", "observations", "observation_labels", "observation_embeddings"] {
        #expect(try countFailureTestRows(table, at: directory.appendingPathComponent("memory.sqlite3")) == 0)
    }
}

private func withFailureTestDatabase<Result>(
    at url: URL,
    _ body: (OpaquePointer) throws -> Result
) throws -> Result {
    var connection: OpaquePointer?
    guard sqlite3_open(url.path, &connection) == SQLITE_OK,
          let connection else {
        if let connection { sqlite3_close_v2(connection) }
        throw FailureTestDatabaseError.open
    }
    defer { sqlite3_close_v2(connection) }
    return try body(connection)
}

@Test
func concurrentMemoryWritesHaveUniqueSequencesAndRejectDuplicates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("memory.sqlite3")
    let store = SQLiteObservationStore(databaseURL: url)
    let engine = MemoryEngine(store: store, classifier: ThrowingMemoryClassifier(), embedder: WorkingMemoryEmbedder(),
                              securityRequirement: .allowsUnencryptedAppPrivatePrototype)
    try await engine.prepare()
    let scope = MemoryScope(userID: "test-user", characterID: "test-character")
    let requests = (0..<12).map {
        MemoryWriteRequest(sourceMessageID: "source-\($0)", sessionID: "session-1",
                           scope: scope, rawText: "나는 포도를 좋아해")
    }
    let sequences = try await withThrowingTaskGroup(of: Int.self) { group in
        for request in requests {
            group.addTask {
                let result = try await engine.remember(request, decision: preferenceDecision())
                return try #require(result.turn).sequence
            }
        }
        var sequences: [Int] = []
        for try await sequence in group { sequences.append(sequence) }
        return sequences
    }
    #expect(Set(sequences).count == requests.count)
    await #expect(throws: SQLiteObservationStoreError.self) {
        try await engine.remember(requests[0], decision: preferenceDecision())
    }
    await engine.close()
    for table in ["conversation_turns", "gate_results", "observations", "observation_labels", "observation_embeddings"] {
        #expect(try countFailureTestRows(table, at: url) == requests.count)
    }
}

private func countFailureTestRows(_ table: String, at url: URL) throws -> Int {
    try withFailureTestDatabase(at: url) { connection in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            "SELECT COUNT(*) FROM \(table);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw FailureTestDatabaseError.statement
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw FailureTestDatabaseError.statement
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

@Test(arguments: RememberFailureStage.allCases)
func failedRememberLeavesNoIncompleteSQLiteRows(
    stage: RememberFailureStage
) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("edgemem.sqlite3")
    let store = SQLiteObservationStore(databaseURL: databaseURL)
    let embedder: (any TextEmbeddingProviding)? =
        stage == .embedding ? ThrowingMemoryEmbedder() : WorkingMemoryEmbedder()
    let engine = MemoryEngine(
        store: store,
        classifier: ThrowingMemoryClassifier(),
        embedder: embedder,
        securityRequirement: .allowsUnencryptedAppPrivatePrototype
    )
    try await engine.prepare()

    let scope = MemoryScope(userID: "test-user", characterID: "test-character")
    let healthy = MemoryEngine(
        store: store, classifier: ThrowingMemoryClassifier(), embedder: WorkingMemoryEmbedder(),
        securityRequirement: .allowsUnencryptedAppPrivatePrototype)
    try await healthy.prepare()
    let existing = try await healthy.remember(
        MemoryWriteRequest(sourceMessageID: "existing", sessionID: "session-1",
                           scope: scope, rawText: "나는 사과를 좋아해"),
        decision: preferenceDecision())
    let originalObservations = try await healthy.activeObservations(in: scope)

    let table: String?
    switch stage {
    case .turnInsert: table = "conversation_turns"
    case .gateInsert: table = "gate_results"
    case .observationInsert, .automaticRollback, .rollbackFailure: table = "observations"
    case .labelInsert: table = "observation_labels"
    case .embeddingInsert: table = "observation_embeddings"
    default: table = nil
    }
    if let table {
        try withFailureTestDatabase(at: databaseURL) { connection in
            let action = stage == .automaticRollback ? "ROLLBACK" : "FAIL"
            guard sqlite3_exec(
                connection,
                "CREATE TRIGGER fail_write BEFORE INSERT ON \(table) " +
                    "BEGIN SELECT RAISE(\(action), 'injected failure'); END;",
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw FailureTestDatabaseError.statement
            }
        }
    }
    if stage == .commit {
        // All INSERTs succeed; a deferred foreign key violation fails COMMIT itself.
        try withFailureTestDatabase(at: databaseURL) { connection in
            let sql = """
                CREATE TABLE commit_parent(id INTEGER PRIMARY KEY);
                CREATE TABLE commit_child(parent_id INTEGER REFERENCES commit_parent(id)
                    DEFERRABLE INITIALLY DEFERRED);
                CREATE TRIGGER fail_write AFTER INSERT ON observation_embeddings
                    BEGIN INSERT INTO commit_child VALUES (99); END;
                """
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
                throw FailureTestDatabaseError.statement
            }
        }
    }

    if stage == .rollbackFailure { try await store.denyRollbackForTest() }
    let request = MemoryWriteRequest(
        sourceMessageID: "failed-source",
        sessionID: "session-1",
        scope: MemoryScope(userID: "test-user", characterID: "test-character"),
        rawText: "나는 포도를 좋아해"
    )
    switch stage {
    case .classification:
        await #expect(throws: InjectedRememberFailure.self) {
            try await engine.remember(request)
        }
    case .embedding:
        await #expect(throws: InjectedRememberFailure.self) {
            try await engine.remember(request, decision: preferenceDecision())
        }
    case .rollbackFailure:
        do {
            _ = try await engine.remember(request, decision: preferenceDecision())
            Issue.record("Expected rollback failure")
        } catch let error as SQLiteObservationStoreError {
            guard case let .rollbackFailed(operation, rollback) = error else {
                Issue.record("Expected combined failure, got \(error)")
                return
            }
            #expect(operation.contains("injected failure"))
            #expect(!rollback.isEmpty)
        }
        await #expect(throws: SQLiteObservationStoreError.databaseNotInitialized) {
            try await store.activeObservations(in: scope)
        }
    default:
        await #expect(throws: SQLiteObservationStoreError.self) {
            try await engine.remember(request, decision: preferenceDecision())
        }
    }
    await engine.close()

    for table in [
        "conversation_turns",
        "gate_results",
        "observations",
        "observation_labels",
        "observation_embeddings",
    ] {
        let count = try countFailureTestRows(table, at: databaseURL)
        #expect(count == 1, "\(stage.rawValue) changed \(table): \(count)")
    }
    try withFailureTestDatabase(at: databaseURL) { connection in
        guard sqlite3_exec(connection, "DROP TRIGGER IF EXISTS fail_write;", nil, nil, nil) == SQLITE_OK else {
            throw FailureTestDatabaseError.statement
        }
    }
    let reopenedStore = SQLiteObservationStore(databaseURL: databaseURL)
    let reopened = MemoryEngine(
        store: reopenedStore, classifier: ThrowingMemoryClassifier(), embedder: WorkingMemoryEmbedder(),
        securityRequirement: .allowsUnencryptedAppPrivatePrototype)
    try await reopened.prepare()
    #expect(try await reopened.activeObservations(in: scope) == originalObservations)
    let retried = try await reopened.remember(request, decision: preferenceDecision())
    let originalTurn = try #require(existing.turn)
    #expect(retried.turn?.sequence == originalTurn.sequence + 1)
    #expect(retried.status == .indexed)
    await reopened.close()
    for table in ["conversation_turns", "gate_results", "observations", "observation_labels", "observation_embeddings"] {
        #expect(try countFailureTestRows(table, at: databaseURL) == 2)
    }
}
