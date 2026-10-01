import Foundation
import XCTest
@testable import EdgeLLM

final class DialogueSessionFileStoreTests: XCTestCase {
    private func temporaryStore() -> DialogueSessionFileStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("petai-chat-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return DialogueSessionFileStore(fileURL: directory.appendingPathComponent("recent-turns.json"))
    }

    func testHomeLineIsDurableBeforeTheNextRequest() throws {
        let store = temporaryStore()
        var session = RoutedPersonaSessionContext(maximumTurnCount: 20)
        XCTAssertEqual(try store.recordHomeLine(in: &session, id: "home-1", text: "밤에 안 잤구나?"), .committed)
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(try restored.snapshot(requestID: "reply").history,
            [.init(role: .assistant, text: "밤에 안 잤구나?")])
        XCTAssertEqual(restored.chatTurns.count, 0)
    }

    func testExistingVersionTwoHistoryCanAddHomeLine() throws {
        let store = temporaryStore()
        let turn = ChatTurn(requestID: "request-1", userMessage: "안녕", assistantMessage: "반가워", status: .completed)
        let old = DialogueSessionCheckpoint(version: 2, maximumTurnCount: 20,
            turns: turn.visibleMessages, completedUserMessages: 1, completedMessages: 2,
            worldInfoState: .init(), worldInfoText: .init(), chatTurns: [turn],
            visibleUserMessages: 1, visibleMessages: 2)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: store.fileURL)
        var restored = try XCTUnwrap(store.load())
        try store.recordHomeLine(in: &restored, id: "home-1", text: "밤에 안 잤구나?")
        let reopened = try XCTUnwrap(store.load())
        XCTAssertEqual(reopened.turns.map(\.text), ["안녕", "반가워", "밤에 안 잤구나?"])
    }

    func testFailedHomeLineSaveDoesNotChangeInMemorySession() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        var session = RoutedPersonaSessionContext(maximumTurnCount: 20)
        XCTAssertThrowsError(try store.recordHomeLine(in: &session, id: "home-1", text: "밤에 안 잤구나?"))
        XCTAssertTrue(session.recentEntries.isEmpty)
    }

    func testAcceptedUserMessageSurvivesRestartWithoutUnfinishedAnswer() throws {
        let store = temporaryStore()
        var session = RoutedPersonaSessionContext(maximumTurnCount: 20)
        _ = try session.beginRequest(requestID: "pending", userMessage: "게임하자")
        try store.save(session)
        try session.appendAssistantText(requestID: "pending", text: "응, 좋아")

        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.chatTurns.count, 1)
        XCTAssertEqual(restored.chatTurns[0].userMessage, "게임하자")
        XCTAssertEqual(restored.chatTurns[0].assistantMessage, "")
        XCTAssertEqual(restored.chatTurns[0].status, .cancelled)
        XCTAssertEqual(restored.completedMessages, 0)
        XCTAssertEqual(try restored.snapshot(requestID: "next").history.count, 1)
    }

    func testTerminalSaveRestoresPartialCancelAndKeepsOnlyTwentyRequests() throws {
        let store = temporaryStore()
        var session = RoutedPersonaSessionContext(maximumTurnCount: 20)
        for index in 0..<22 {
            let id = "request-\(index)"
            _ = try store.beginRequest(in: &session, requestID: id, userMessage: "질문 \(index)")
            if index == 21 {
                try session.appendAssistantText(requestID: id, text: "부분 답변")
                try store.finishRequest(in: &session, requestID: id, status: .cancelled)
            } else {
                try store.finishRequest(in: &session, requestID: id,
                    status: .completed, assistantMessage: "답변 \(index)")
            }
        }

        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.chatTurns.count, 20)
        XCTAssertEqual(restored.chatTurns.first?.userMessage, "질문 2")
        XCTAssertEqual(restored.chatTurns.last?.assistantMessage, "부분 답변")
        XCTAssertEqual(restored.chatTurns.last?.status, .cancelled)
        XCTAssertEqual(restored.visibleUserMessages, 22)
        XCTAssertEqual(restored.completedUserMessages, 21)
    }

    func testAdmissionAtCapacityPersistsTheNewWindow() throws {
        let store = temporaryStore()
        var session = RoutedPersonaSessionContext(maximumTurnCount: 3)
        for index in 1...3 {
            let id = "turn-\(index)"
            _ = try store.beginRequest(in: &session, requestID: id, userMessage: "질문 \(index)")
            try store.finishRequest(in: &session, requestID: id,
                status: .completed, assistantMessage: "답변 \(index)")
        }

        let current = try store.beginRequest(in: &session,
            requestID: "turn-4", userMessage: "질문 4")
        XCTAssertEqual(current.history.map(\.text), ["질문 2", "답변 2", "질문 3", "답변 3"])
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.chatTurns.map(\.requestID), ["turn-2", "turn-3", "turn-4"])
        XCTAssertEqual(restored.chatTurns.last?.status, .cancelled)
    }

    func testCorruptFileFailsInsteadOfStartingEmptyConversation() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: store.fileURL)

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), Data("invalid".utf8))
    }

    func testSemanticallyInvalidCompletedTurnIsRejected() throws {
        let store = temporaryStore()
        let invalid = DialogueSessionCheckpoint(version: 2, maximumTurnCount: 20,
            turns: [.init(role: .user, text: "게임하자")],
            completedUserMessages: 1, completedMessages: 2,
            worldInfoState: .init(), worldInfoText: .init(),
            chatTurns: [.init(requestID: "bad", userMessage: "게임하자", status: .completed)],
            visibleUserMessages: 1, visibleMessages: 2)
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try JSONEncoder().encode(invalid).write(to: store.fileURL)

        XCTAssertThrowsError(try store.load())
    }

    func testFailedAcceptanceDoesNotEnterInMemoryHistory() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        var session = RoutedPersonaSessionContext(maximumTurnCount: 3)
        for index in 1...3 {
            XCTAssertTrue(session.appendExchange(userMessage: "질문 \(index)", assistantMessage: "답변 \(index)"))
        }

        XCTAssertThrowsError(try store.beginRequest(in: &session,
            requestID: "not-accepted", userMessage: "게임하자"))
        XCTAssertEqual(session.chatTurns.map(\.userMessage), ["질문 1", "질문 2", "질문 3"])
        XCTAssertEqual(session.visibleUserMessages, 3)
    }

    func testFailedTerminalSaveKeepsActiveTurnForDiskRecovery() throws {
        let store = temporaryStore()
        var session = RoutedPersonaSessionContext()
        _ = try store.beginRequest(in: &session, requestID: "pending", userMessage: "게임하자")
        try session.appendAssistantText(requestID: "pending", text: "좋아")
        let invalidStore = DialogueSessionFileStore(fileURL: store.fileURL.appendingPathComponent("nested"))

        XCTAssertThrowsError(try invalidStore.finishRequest(in: &session,
            requestID: "pending", status: .completed, assistantMessage: "좋아"))
        XCTAssertEqual(session.chatTurns.last?.status, .inProgress)
        XCTAssertEqual(session.completedMessages, 0)
        let recovered = try XCTUnwrap(store.load())
        XCTAssertEqual(recovered.chatTurns.last?.status, .cancelled)
        XCTAssertEqual(recovered.chatTurns.last?.assistantMessage, "")
    }

    func testSaveExcludesDirectoryFromBackupAndRemoveIsIdempotent() throws {
        let store = temporaryStore()
        XCTAssertNil(try store.load())
        try store.save(RoutedPersonaSessionContext())
        XCTAssertEqual(try store.fileURL.deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try store.remove()
        try store.remove()
        XCTAssertNil(try store.load())
    }
}
