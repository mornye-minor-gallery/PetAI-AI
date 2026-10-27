import Foundation
import Testing
@testable import EdgeLLM

@Test func memoryDatabaseConcurrentReadersShareOneConnection() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = MemoryDatabase(databaseURL: directory.appendingPathComponent("memory.sqlite3"))
    let stores = try await withThrowingTaskGroup(of: SQLiteObservationStore.self) { group in
        for _ in 0..<32 {
            group.addTask {
                let store = try await database.preparedStore()
                #expect(try await store.allDiaries().isEmpty)
                return store
            }
        }
        var results: [SQLiteObservationStore] = []
        for try await store in group { results.append(store) }
        return results
    }
    #expect(stores.count == 32)
    #expect(stores.allSatisfy { $0 === stores[0] })
}

@Test func memoryDatabaseSurvivesEngineSuspensionAndErasure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = MemoryDatabase(databaseURL: directory.appendingPathComponent("memory.sqlite3"))
    let store = try await database.preparedStore()
    let engine = MemoryEngine(store: store, classifier: DatabaseUnusedClassifier(),
        securityRequirement: .allowsUnencryptedAppPrivatePrototype)
    try await engine.prepare()
    _ = try await store.insertDiaryIfAbsent(characterID: "test", localDate: "2026-10-11",
        draft: .init(title: "산책", body: "공원을 걸었어요."))
    await engine.suspend()
    // Read directly: reopening here would hide an incorrectly closed connection.
    #expect(try await store.allDiaries().count == 1)
    await #expect(throws: MemoryEngineError.notPrepared) {
        try await engine.activeObservations(in: .init(userID: "test", characterID: "test"))
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await store.eraseAllMemories() }
        for _ in 0..<16 { group.addTask { _ = try await store.allDiaries() } }
        try await group.waitForAll()
    }
    #expect(try await store.allDiaries().isEmpty)
    #expect(try await database.preparedStore() === store)
    try await engine.prepare()
    #expect(try await engine.activeObservations(in: .init(userID: "test", characterID: "test")).isEmpty)
}

private struct DatabaseUnusedClassifier: MemoryObservationClassifying {
    let version = "unused"
    func evaluate(_ text: String) async throws -> MemoryGateDecision {
        throw MemoryEngineError.notPrepared
    }
}

@Test func memoryDatabaseDoesNotPublishFailedInitialization() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("memory.sqlite3")
    try Data("not a sqlite database".utf8).write(to: url)
    let database = MemoryDatabase(databaseURL: url)
    for _ in 0..<2 {
        await #expect(throws: (any Error).self) { _ = try await database.preparedStore() }
    }
    try FileManager.default.removeItem(at: url)
    let store = try await database.preparedStore()
    #expect(try await store.allDiaries().isEmpty)
}
