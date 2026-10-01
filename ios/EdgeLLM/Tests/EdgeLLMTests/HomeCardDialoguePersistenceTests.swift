import Foundation
import XCTest
@testable import EdgeLLM

final class HomeCardDialoguePersistenceTests: XCTestCase {
    func testSelectedSharedHomeLineSurvivesRestartAndEntersNextPromptHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-card-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DialogueSessionFileStore(fileURL: directory.appendingPathComponent("recent-turns.json"))
        let selectedLine = "창가는 내가 찜! 별이 제일 잘 보이잖아. 밤마다 여기 앉아서 세고 있을 거야."
        var session = RoutedPersonaSessionContext(maximumTurnCount: 20)
        try store.recordHomeLine(in: &session, id: "home-card-2", text: selectedLine)

        var restored = try XCTUnwrap(store.load())
        let next = try store.beginRequest(in: &restored, requestID: "next-question", userMessage: "창가 좋아해?")
        XCTAssertEqual(next.history, [.init(role: .assistant, text: selectedLine)])
        XCTAssertEqual(restored.chatTurns.count, 1)
    }
}
