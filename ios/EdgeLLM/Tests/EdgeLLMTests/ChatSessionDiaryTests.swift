import Foundation
import XCTest
@testable import EdgeLLM

final class ChatSessionDiaryTests: XCTestCase {
    func testNoMemoriesDoesNotStartDiaryInference() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.controller.requestDiary(requestId: "empty", localDate: "2026-09-27")
        let event = try await terminalEvent("empty", in: fixture.events)
        XCTAssertEqual(event.type, "diary_failed")
        XCTAssertEqual(event.message, DailyDiaryError.noMemories.localizedDescription)
        let generations = await fixture.runtime.diaryGenerationCount
        XCTAssertEqual(generations, 0)
    }

    func testCompletedDayNeverGeneratesAgain() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        let day = try DailyDiaryDay("2026-09-27")
        let evidence = MemoryObservation(id: "observation", turnID: "turn", sessionID: "session",
            sequence: 1, scope: MemoryScope(userID: "local-user", characterID: "test"),
            occurredAt: day.start.addingTimeInterval(3600), rawText: "산책했어요.",
            labelEvidence: [MemoryLabelEvidence(label: .event, score: nil, source: .regex,
                classifierVersion: "test")], createdAt: day.start)
        await fixture.memory.setDiaryObservations([evidence])
        await fixture.controller.requestDiary(requestId: "first", localDate: day.key)
        let first = try await terminalEvent("first", in: fixture.events)
        XCTAssertEqual(first.type, "diary_completed")
        await fixture.memory.setDiaryObservations([])
        await fixture.controller.requestDiary(requestId: "again", localDate: day.key)
        let again = try await terminalEvent("again", in: fixture.events)
        XCTAssertEqual(again.type, "diary_completed")
        XCTAssertEqual(first.diary?.title, again.diary?.title)
        let generations = await fixture.runtime.diaryGenerationCount
        XCTAssertEqual(generations, 1)
    }

    func testUnexpectedFailureDoesNotExposeInternalErrorToPlayer() async throws {
        struct PrivateFailure: LocalizedError {
            var errorDescription: String? { "private storage location" }
        }
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        let day = try DailyDiaryDay("2026-09-27")
        let evidence = MemoryObservation(id: "observation", turnID: "turn", sessionID: "session",
            sequence: 1, scope: MemoryScope(userID: "local-user", characterID: "test"),
            occurredAt: day.start.addingTimeInterval(3600), rawText: "산책했어요.",
            labelEvidence: [MemoryLabelEvidence(label: .event, score: nil, source: .regex,
                classifierVersion: "test")], createdAt: day.start)
        await fixture.memory.setDiaryObservations([evidence])
        await fixture.runtime.failDiary(with: PrivateFailure())
        await fixture.controller.requestDiary(requestId: "failed", localDate: day.key)
        let event = try await terminalEvent("failed", in: fixture.events)
        XCTAssertEqual(event.type, "diary_failed")
        XCTAssertEqual(event.message, "일기를 만들지 못했어요. 다시 시도해 주세요.")
    }

    private func terminalEvent(_ requestID: String, in events: ChatEventRecorder) async throws -> NativeChatEvent {
        for _ in 0..<1_000 {
            if let event = events.snapshot().last(where: {
                $0.requestId == requestID && ($0.type == "diary_completed" || $0.type == "diary_failed")
            }) { return event }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NSError(domain: "DiaryTest", code: 1)
    }
}
