import Foundation
import Testing
@testable import EdgeLLM

@Test
func sqliteStorePersistsCharacterScopedMemoryAcrossReopen() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = temporaryDirectory
        .appendingPathComponent("edgemem.sqlite3", isDirectory: false)
    defer {
        try? FileManager.default.removeItem(at: temporaryDirectory)
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
        securityRequirement: .allowsUnencryptedAppPrivatePrototype,
        makeObservationID: { "observation-emu" },
        now: { timestamp }
    )
    try await engine.prepare()

    let result = try await engine.remember(
        MemoryWriteRequest(
            sourceMessageID: "message-emu",
            sessionID: "session-1",
            scope: emuScope,
            rawText: "  나는 포도를 좋아해  ",
            occurredAt: timestamp
        )
    )
    guard case let .stored(storedObservation) = result else {
        Issue.record("Expected the preference observation to be stored.")
        return
    }

    try await store.save(
        MemoryObservation(
            id: "observation-other",
            sourceMessageID: "message-other",
            sessionID: "session-1",
            scope: otherScope,
            occurredAt: timestamp,
            rawText: "어제 미술관에 다녀왔어",
            labels: [MemoryLabel.event],
            classifierVersion: "test-classifier-v1",
            createdAt: timestamp,
            updatedAt: timestamp
        )
    )

    let emuObservations = try await engine.activeObservations(in: emuScope)
    #expect(emuObservations == [storedObservation])
    #expect(emuObservations[0].rawText == "  나는 포도를 좋아해  ")
    #expect(emuObservations[0].classifierVersion == "naive-keyword-ko-v1")
    #expect(FileManager.default.fileExists(atPath: databaseURL.path))

    await engine.close()

    let reopenedStore = SQLiteObservationStore(databaseURL: databaseURL)
    let reopenedEngine = MemoryEngine(
        store: reopenedStore,
        securityRequirement: .allowsUnencryptedAppPrivatePrototype
    )
    try await reopenedEngine.prepare()

    #expect(
        try await reopenedEngine.activeObservations(in: emuScope)
            == [storedObservation]
    )
    #expect(
        try await reopenedEngine.activeObservations(in: otherScope).count
            == 1
    )

    await #expect(
        throws: SQLiteObservationStoreError.unknownObservation(
            storedObservation.id
        )
    ) {
        try await reopenedEngine.deleteObservation(
            observationID: storedObservation.id,
            in: otherScope
        )
    }
    #expect(
        try await reopenedEngine.activeObservations(in: emuScope)
            == [storedObservation]
    )

    try await reopenedEngine.deleteObservation(
        observationID: storedObservation.id,
        in: emuScope
    )
    #expect(
        try await reopenedEngine.activeObservations(in: emuScope).isEmpty
    )

    await reopenedEngine.close()
}

@Test
func encryptedRequirementRejectsThePlainSQLitePrototypeStore() async {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let databaseURL = temporaryDirectory
        .appendingPathComponent("edgemem.sqlite3", isDirectory: false)
    defer {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let store = SQLiteObservationStore(databaseURL: databaseURL)
    let engine = MemoryEngine(store: store)

    await #expect(throws: MemoryEngineError.insecureStoreConfiguration) {
        try await engine.prepare()
    }
}
