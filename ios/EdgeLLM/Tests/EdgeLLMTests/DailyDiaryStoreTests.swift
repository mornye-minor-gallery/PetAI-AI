import Foundation
import Testing
@testable import EdgeLLM

@Suite struct DailyDiaryStoreTests {
    @Test func completedDiaryIsImmutableAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("memory.sqlite3")
        let first = SQLiteObservationStore(databaseURL: url)
        try await first.initialize()
        let date = "2026-09-27"
        let saved = try await first.insertDiaryIfAbsent(characterID: "character", localDate: date,
            draft: DailyDiaryDraft(title: "첫 일기", body: "산책했어요."))
        #expect(saved.title == "첫 일기")
        await first.close()
        let second = SQLiteObservationStore(databaseURL: url)
        try await second.initialize()
        let existing = try await second.insertDiaryIfAbsent(characterID: "character", localDate: date,
            draft: DailyDiaryDraft(title: "바뀐 일기", body: "다른 내용이에요."))
        #expect(existing == saved)
        #expect(try await second.allDiaries().count == 1)
        await second.close()
    }

    @Test func daysAndCharactersAreSeparateAndDeletionIsComplete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteObservationStore(databaseURL: directory.appendingPathComponent("memory.sqlite3"))
        try await store.initialize()
        let draft = DailyDiaryDraft(title: "하루", body: "쉬었어요.")
        _ = try await store.insertDiaryIfAbsent(characterID: "one", localDate: "2026-09-27", draft: draft)
        _ = try await store.insertDiaryIfAbsent(characterID: "two", localDate: "2026-09-27", draft: draft)
        _ = try await store.insertDiaryIfAbsent(characterID: "one", localDate: "2026-09-26", draft: draft)
        #expect(try await store.allDiaries().count == 3)
        try await store.eraseAllMemories()
        #expect(try await store.allDiaries().isEmpty)
        await store.close()
    }
}
