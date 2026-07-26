import Foundation
import SQLite3
import Testing
@testable import EdgeLLM

private struct SQLiteTestClassifier: MemoryObservationClassifying {
    let version = "sqlite-test-gate-v1"
    let label: MemoryGateLabel

    func evaluate(_ text: String) async throws -> MemoryGateDecision {
        MemoryGateDecision(
            label: label,
            regex: MemoryRegexGateResult(
                preferenceHit: label == .preference || label == .both,
                eventHit: label == .event || label == .both
            ),
            preferenceScore: nil,
            eventScore: nil,
            preferenceThreshold: 0.08,
            eventThreshold: 0.08,
            classifierVersion: version,
            embeddingModelID: nil
        )
    }
}

private struct SQLiteFailingClassifier: MemoryObservationClassifying {
    struct UnexpectedEvaluation: Error {}

    let version = "must-not-run"

    func evaluate(_ text: String) async throws -> MemoryGateDecision {
        throw UnexpectedEvaluation()
    }
}

private struct SQLiteDenseTestEmbedder: TextEmbeddingProviding {
    let modelID = "sqlite-dense-test-v1"
    let dimension = 3

    func embedQuery(_ text: String) async throws -> [Float] {
        [1, 0, 0]
    }

    func embedDocument(_ text: String) async throws -> [Float] {
        [1, 0, 0]
    }
}

@Test
func sqliteStorePersistsCharacterScopedObservationsAcrossReopen() async throws {
    let directory = temporaryMemoryDirectory()
    let databaseURL = directory.appendingPathComponent("edgemem.sqlite3")
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let timestamp = Date(timeIntervalSince1970: 1_721_280_000)
    let emuScope = MemoryScope(
        userID: "local-user",
        characterID: "emu"
    )
    let otherScope = MemoryScope(
        userID: "local-user",
        characterID: "other-character"
    )
    let store = SQLiteObservationStore(databaseURL: databaseURL)
    let engine = MemoryEngine(
        store: store,
        classifier: SQLiteTestClassifier(label: .preference),
        securityRequirement: .allowsUnencryptedAppPrivatePrototype,
        now: { timestamp }
    )
    try await engine.prepare()

    let emuResult = try await engine.remember(
        MemoryWriteRequest(
            sourceMessageID: "message-emu",
            sessionID: "session-1",
            scope: emuScope,
            rawText: "  나는 포도를 좋아해  ",
            occurredAt: timestamp
        )
    )
    let otherResult = try await engine.remember(
        MemoryWriteRequest(
            sourceMessageID: "message-other",
            sessionID: "session-1",
            scope: otherScope,
            rawText: "나는 딸기를 좋아해",
            occurredAt: timestamp
        )
    )
    let emuObservation = try #require(emuResult.observation)
    #expect(otherResult.observation != nil)
    #expect(
        try await engine.activeObservations(in: emuScope)
            == [emuObservation]
    )
    #expect(
        try await engine.activeObservations(in: otherScope).count == 1
    )
    #expect(FileManager.default.fileExists(atPath: databaseURL.path))
    await engine.close()

    let reopenedStore = SQLiteObservationStore(databaseURL: databaseURL)
    let reopenedEngine = MemoryEngine(
        store: reopenedStore,
        classifier: SQLiteTestClassifier(label: .preference),
        securityRequirement: .allowsUnencryptedAppPrivatePrototype
    )
    try await reopenedEngine.prepare()

    #expect(
        try await reopenedEngine.activeObservations(in: emuScope)
            == [emuObservation]
    )
    await #expect(
        throws: SQLiteObservationStoreError.unknownObservation(
            emuObservation.id
        )
    ) {
        try await reopenedEngine.deleteObservation(
            observationID: emuObservation.id,
            in: otherScope
        )
    }
    try await reopenedEngine.deleteObservation(
        observationID: emuObservation.id,
        in: emuScope
    )
    #expect(
        try await reopenedEngine.activeObservations(in: emuScope).isEmpty
    )
    await reopenedEngine.close()
}

@Test
func sqliteStoreDoesNotPersistUnlabeledObservationOrEmbedding() async throws {
    let directory = temporaryMemoryDirectory()
    let databaseURL = directory.appendingPathComponent("edgemem.sqlite3")
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let scope = MemoryScope(userID: "local-user", characterID: "emu")
    let store = SQLiteObservationStore(databaseURL: databaseURL)
    let embedder = SQLiteDenseTestEmbedder()
    let engine = MemoryEngine(
        store: store,
        classifier: SQLiteTestClassifier(label: .none),
        embedder: embedder,
        securityRequirement: .allowsUnencryptedAppPrivatePrototype
    )
    try await engine.prepare()

    let result = try await engine.remember(
        MemoryWriteRequest(
            sourceMessageID: "message-1",
            sessionID: "session-1",
            scope: scope,
            rawText: "다시 쉽게 설명해줘"
        )
    )
    #expect(result.status == .skippedNoMemorySignal)
    #expect(result.observation == nil)
    await engine.close()

    let reopenedStore = SQLiteObservationStore(databaseURL: databaseURL)
    try await reopenedStore.initialize()
    let retriever = DenseMemoryRetriever(
        candidateLoader: reopenedStore,
        embedder: embedder
    )
    let results = try await retriever.search(
        MemorySearchRequest(
            scope: scope,
            query: "설명"
        )
    )

    #expect(results.isEmpty)
    await reopenedStore.close()
}

@Test
func taggedChatAxesPersistExactSQLiteLabelsWithoutClassifierFallback()
    async throws
{
    let directory = temporaryMemoryDirectory()
    let databaseURL = directory.appendingPathComponent("edgemem.sqlite3")
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let scope = MemoryScope(userID: "local-user", characterID: "emu")
    let engine = MemoryEngine(
        store: SQLiteObservationStore(databaseURL: databaseURL),
        classifier: SQLiteFailingClassifier(),
        securityRequirement: .allowsUnencryptedAppPrivatePrototype
    )
    try await engine.prepare()

    let cases: [
        (
            id: String,
            label: MemoryGateLabel,
            expected: [MemoryLabel]?
        )
    ] = [
        ("message-none", MemoryGateLabel.none, nil),
        ("message-preference", .preference, [.preference]),
        ("message-event", .event, [.event]),
        ("message-both", .both, [.event, .preference]),
    ]

    for item in cases {
        let result = try await engine.remember(
            MemoryWriteRequest(
                sourceMessageID: item.id,
                sessionID: "session-axes",
                scope: scope,
                rawText: "축분해 저장 테스트 \(item.id)"
            ),
            decision: .taggedChat(item.label)
        )

        if let expected = item.expected {
            #expect(result.status == .indexed)
            #expect(result.observation?.labels == expected)
        } else {
            #expect(result.status == .skippedNoMemorySignal)
            #expect(result.observation == nil)
        }
    }

    let observations = try await engine.activeObservations(in: scope)
    #expect(observations.count == 3)
    #expect(
        observations.contains { $0.labels == [.preference] }
    )
    #expect(
        observations.contains { $0.labels == [.event] }
    )
    #expect(
        observations.contains {
            $0.labels == [.event, .preference]
        }
    )
    await engine.close()
}

@Test
func canonicalStoreResetsTheOldPrototypeSchema() async throws {
    let directory = temporaryMemoryDirectory()
    let databaseURL = directory.appendingPathComponent("edgemem.sqlite3")
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    let legacySQL =
        """
        CREATE TABLE schema_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        INSERT INTO schema_metadata VALUES ('schema_version', '1');
        CREATE TABLE memory_observations (
            observation_id TEXT PRIMARY KEY,
            raw_text TEXT NOT NULL
        );
        INSERT INTO memory_observations VALUES ('legacy', 'test memory');
        """
    #expect(sqlite3_exec(database, legacySQL, nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(database)

    let store = SQLiteObservationStore(databaseURL: databaseURL)
    try await store.initialize()
    #expect(
        try await store.activeObservations(
            in: MemoryScope(
                userID: "local-user",
                characterID: "emu"
            )
        ).isEmpty
    )
    await store.close()

    var reopened: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &reopened) == SQLITE_OK)
    defer {
        sqlite3_close_v2(reopened)
    }
    #expect(tableExists("conversation_turns", in: reopened))
    #expect(!tableExists("memory_observations", in: reopened))
}

@Test
func canonicalVersionOneMigratesAndPreservesExistingLabels() async throws {
    let directory = temporaryMemoryDirectory()
    let databaseURL = directory.appendingPathComponent("edgemem.sqlite3")
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    let versionOneSQL =
        """
        CREATE TABLE schema_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        INSERT INTO schema_metadata VALUES ('schema_version', '1');
        CREATE TABLE conversation_turns (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            role TEXT NOT NULL,
            text TEXT NOT NULL,
            occurred_at TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            deleted_at TEXT
        );
        CREATE TABLE observations (
            id TEXT PRIMARY KEY,
            turn_id TEXT NOT NULL UNIQUE,
            state TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE observation_labels (
            observation_id TEXT NOT NULL,
            label TEXT NOT NULL,
            score REAL,
            source TEXT NOT NULL CHECK (
                source IN (
                    'regex',
                    'prototype',
                    'regex+prototype',
                    'future_mlp'
                )
            ),
            classifier_version TEXT NOT NULL,
            PRIMARY KEY (observation_id, label)
        );
        INSERT INTO conversation_turns VALUES (
            'turn-v1',
            'local-user',
            'emu',
            'session-v1',
            0,
            'user',
            '나는 딸기를 좋아해',
            '2024-07-16T00:00:00.000Z',
            'hash-v1',
            NULL
        );
        INSERT INTO observations VALUES (
            'observation-v1',
            'turn-v1',
            'active',
            '2024-07-16T00:00:00.000Z'
        );
        INSERT INTO observation_labels VALUES (
            'observation-v1',
            'preference',
            NULL,
            'regex',
            'legacy-v1'
        );
        """
    #expect(
        sqlite3_exec(
            database,
            versionOneSQL,
            nil,
            nil,
            nil
        ) == SQLITE_OK
    )
    sqlite3_close_v2(database)

    let store = SQLiteObservationStore(databaseURL: databaseURL)
    try await store.initialize()
    let observations = try await store.activeObservations(
        in: MemoryScope(userID: "local-user", characterID: "emu")
    )

    #expect(observations.count == 1)
    #expect(observations.first?.labels == [.preference])
    #expect(
        observations.first?.labelEvidence.first?.source == .regex
    )
    await store.close()
}

@Test
func encryptedRequirementRejectsPlainSQLiteStore() async {
    let directory = temporaryMemoryDirectory()
    let databaseURL = directory.appendingPathComponent("edgemem.sqlite3")
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let engine = MemoryEngine(
        store: SQLiteObservationStore(databaseURL: databaseURL),
        classifier: SQLiteTestClassifier(label: .none)
    )

    await #expect(throws: MemoryEngineError.insecureStoreConfiguration) {
        try await engine.prepare()
    }
}

private func temporaryMemoryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func tableExists(
    _ name: String,
    in database: OpaquePointer?
) -> Bool {
    var statement: OpaquePointer?
    guard
        sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement
    else {
        return false
    }
    defer {
        sqlite3_finalize(statement)
    }
    name.withCString {
        sqlite3_bind_text(
            statement,
            1,
            $0,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
    }
    return sqlite3_step(statement) == SQLITE_ROW
}
