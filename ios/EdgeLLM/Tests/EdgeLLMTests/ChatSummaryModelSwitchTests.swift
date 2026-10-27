import XCTest
@testable import EdgeLLM

final class ChatSummaryModelSwitchTests: XCTestCase {
    func testCharacterSwitchPreservesAndBoundsSummaryFromAnotherModel() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        let other = try DialogueSessionFileStore.character("lucia", in: fixture.directory)
        var session = RoutedPersonaSessionContext()
        _ = session.appendExchange(userMessage: "짧은 질문", assistantMessage: "짧은 답")
        try other.compact(in: &session, retaining: session.contextEntries,
            summary: String(repeating: "가", count: 600), modelIdentifier: "previous-model")
        await fixture.controller.initialize()
        await fixture.controller.activateCharacter("lucia")
        XCTAssertEqual(fixture.events.snapshot().last?.type, "ready")
        let restored = try XCTUnwrap(other.load())
        XCTAssertEqual(restored.summary, String(repeating: "가", count: 500))
        XCTAssertEqual(restored.contextEntries, session.contextEntries)
        XCTAssertNotEqual(restored.summaryModelIdentifier, "previous-model")
    }

    func testInitializationPreservesSummaryFromAnotherModel() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        var session = RoutedPersonaSessionContext()
        try fixture.store.compact(in: &session, retaining: [], summary: "전에 나눈 중요한 이야기", modelIdentifier: "previous-model")
        await fixture.controller.initialize()
        XCTAssertEqual(fixture.events.snapshot().last?.type, "ready")
        XCTAssertEqual(try fixture.store.load()?.summary, "전에 나눈 중요한 이야기")
        XCTAssertNotEqual(try fixture.store.load()?.summaryModelIdentifier, "previous-model")
    }
}
