import XCTest
@testable import EdgeLLM

final class DialogueCheckpointTests: XCTestCase {
    func testRestoreKeepsClockAfterHistoryTruncation() throws {
        var original = RoutedPersonaSessionContext(maximumTurnCount: 2)
        for index in 0..<12 { original.appendExchange(userMessage: "u\(index)", assistantMessage: "a\(index)") }
        let data = try JSONEncoder().encode(original.checkpoint())
        let saved = try JSONDecoder().decode(DialogueSessionCheckpoint.self, from: data)
        var restored = try RoutedPersonaSessionContext(checkpoint: saved)
        XCTAssertEqual(restored.turns.count, 4)
        XCTAssertEqual(restored.completedMessages, 24)
        let pending = try restored.snapshot(requestID: "next")
        try restored.commit(pending, userMessage: "next", assistantMessage: "answer")
        try restored.commit(pending, userMessage: "next", assistantMessage: "answer")
        XCTAssertEqual(restored.completedMessages, 26)
        XCTAssertEqual(DialogueSeedPolicy.worldInfo(base: 42, completedMessages: 24), 66)
    }

    func testInvalidCheckpointRejected() throws {
        let invalid = DialogueSessionCheckpoint(version: 1, maximumTurnCount: 20, turns: [],
            completedUserMessages: 5, completedMessages: 2, worldInfoState: .init(), worldInfoText: .init())
        XCTAssertThrowsError(try RoutedPersonaSessionContext(checkpoint: invalid)) { error in
            XCTAssertEqual(error as? DialogueSessionError, .invalidCheckpoint)
        }
    }

    func testVersionOneCheckpointRestoresForEvaluationConsumer() throws {
        let old = DialogueSessionCheckpoint(version: 1, maximumTurnCount: 2,
            turns: [.init(role: .user, text: "old"), .init(role: .assistant, text: "answer")],
            completedUserMessages: 12, completedMessages: 24,
            worldInfoState: .init(), worldInfoText: .init())
        let data = try JSONEncoder().encode(old)
        let restored = try RoutedPersonaSessionContext(checkpoint: JSONDecoder().decode(DialogueSessionCheckpoint.self, from: data))
        XCTAssertEqual(restored.chatTurns.count, 1)
        XCTAssertEqual(restored.visibleUserMessages, 12)
        XCTAssertEqual(restored.visibleMessages, 24)
        XCTAssertEqual(restored.turns, old.turns)
    }
}
