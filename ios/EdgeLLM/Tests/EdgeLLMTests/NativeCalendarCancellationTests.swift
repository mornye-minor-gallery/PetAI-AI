import Foundation
import XCTest
@testable import EdgeLLM

final class NativeCalendarCancellationTests: XCTestCase {
    func testCancelledCalendarReadDiscardsLateResult() async throws {
        let tools = PausedCalendarTools(tool: .getCalendarEvents, result: .object(["events": .array([])]))
        let fixture = try ChatControllerFixture(tools: tools)
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.controller.useCalendarTestRoute(.getCalendarEvents)
        await fixture.runtime.setFunctionCall(.init(name: "get_calendar_events", argumentsJSON:
            #"{"startDate":"2026-10-15","endDate":"2026-10-15"}"#))
        let sending = Task { await fixture.controller.send(json: fixture.request("calendar-read", "오늘 일정 알려 줘", allowedTools: [.getCalendarEvents])) }
        await tools.waitForExecution()
        await fixture.controller.cancel(requestID: "calendar-read")
        await tools.finish()
        await sending.value
        let turn = try XCTUnwrap(fixture.store.load()?.chatTurns.last)
        XCTAssertEqual(turn.status, .cancelled)
        XCTAssertEqual(turn.assistantMessage, "")
        XCTAssertFalse(fixture.events.snapshot().contains { $0.type == "completed" })
        let cancelled = await tools.cancellationObserved
        XCTAssertTrue(cancelled)
    }

    func testCommittedCalendarWriteIsStillReportedAfterLateCancel() async throws {
        let tools = PausedCalendarTools(tool: .createCalendarEvent, result: .object([
            "eventIdentifier": .string("test-event"), "title": .string("test meeting"),
            "startDateTime": .string("2099-01-01T09:00:00Z"), "endDateTime": .string("2099-01-01T10:00:00Z")
        ]))
        let fixture = try ChatControllerFixture(tools: tools)
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.controller.useCalendarTestRoute(.createCalendarEvent)
        await fixture.runtime.setFunctionCall(.init(name: "create_calendar_event", argumentsJSON:
            #"{"title":"test meeting","startDateTime":"2099-01-01T09:00","endDateTime":"2099-01-01T10:00"}"#))
        let sending = Task { await fixture.controller.send(json: fixture.request("calendar-write", "내일 일정 추가해 줘", allowedTools: [.createCalendarEvent])) }
        await tools.waitForExecution()
        await fixture.controller.cancel(requestID: "calendar-write")
        await tools.finish()
        await sending.value
        let persisted = try fixture.store.load()
        XCTAssertEqual(persisted?.chatTurns.last?.status, .completed)
        XCTAssertTrue(fixture.events.snapshot().contains { $0.type == "completed" && $0.presentation == .tool })
    }
}

private extension ChatSessionController {
    func useCalendarTestRoute(_ tool: NativeToolKind) { nativeToolRouter = CalendarTestRouter(tool: tool) }
}
private struct CalendarTestRouter: NativeToolRouting {
    let tool: NativeToolKind
    func route(_ utterance: String) -> NativeToolRoute { .tool(tool) }
}
private actor PausedCalendarTools: ChatPlatformTools {
    nonisolated let supportedTools: Set<NativeToolKind>
    nonisolated let unsupportedMessage = "Unsupported test tool"
    private let result: JSONValue
    private var pending: CheckedContinuation<JSONValue, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private var executing = false
    private(set) var cancellationObserved = false
    init(tool: NativeToolKind, result: JSONValue) { supportedTools = [tool]; self.result = result }
    func enrich(_ base: UserProfileContext, allowedTools: Set<NativeToolKind>) -> UserProfileContext { base }
    func confirm(_ draft: NativeToolProposal) -> NativeToolProposal { draft }
    func cancelConfirmation() {}
    func cancelExecution(requestID: String) async { cancellationObserved = true }
    func execute(_ proposal: ValidatedToolProposal) async -> JSONValue {
        await withCheckedContinuation { pending = $0; executing = true; waiting?.resume(); waiting = nil }
    }
    func waitForExecution() async {
        if !executing { await withCheckedContinuation { waiting = $0 } }
    }
    func finish() { pending?.resume(returning: result); pending = nil }
}
