import Foundation
import XCTest
@testable import EdgeLLM

final class NativeToolReplyTests: XCTestCase {
    func testSuccessfulAlarmWithMalformedDateIsStillCompletedAndObservable() async throws {
        let tools = ToolReplyAdapter(data: .object([
            "label": .string("내일 아침 알람"), "scheduledAt": .string("malformed-test-date"),
        ]))
        let logs = ToolReplyLogs()
        let fixture = try ChatControllerFixture(tools: tools, log: logs.append)
        defer { fixture.remove() }
        try await sendAlarm(using: fixture)

        let saved = try XCTUnwrap(fixture.store.load()?.chatTurns.last)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.assistantMessage, "알람은 맞춰뒀는데, 예약 시각을 표시하지 못했어.")
        XCTAssertTrue(fixture.events.snapshot().contains {
            $0.type == "completed" && $0.presentation == .tool && $0.text == saved.assistantMessage
        })
        XCTAssertFalse(fixture.events.snapshot().contains { $0.type == "error" || $0.type == "cancelled" })
        let executed = await tools.executed
        XCTAssertEqual(executed.count, 1)
        guard case .createAlarm(_, let label) = try XCTUnwrap(executed.first).arguments else {
            return XCTFail("Expected the original alarm proposal")
        }
        XCTAssertEqual(label, "내일 아침 알람")
        XCTAssertTrue(logs.snapshot().contains { $0.contains("native_tool_result_format_failed") && $0.contains("scheduledAt") })
        XCTAssertFalse(logs.snapshot().contains { $0.contains("malformed-test-date") || $0.contains("내일 아침 알람") })
        let generations = await fixture.runtime.generationCount
        let proposalCalls = await fixture.runtime.functionCallCount
        let checkpoints = await fixture.runtime.checkpointCount
        XCTAssertEqual(generations, 0)
        XCTAssertEqual(proposalCalls, 1)
        XCTAssertEqual(checkpoints, 0)
    }

    func testSuccessfulAlarmFormatsTheActualResultWithoutRepeatingItsLabel() async throws {
        let tools = ToolReplyAdapter(data: .object([
            "label": .string("내일 아침 알람"), "scheduledAt": .string("2099-01-01T00:00:00Z"),
        ]))
        let fixture = try ChatControllerFixture(tools: tools)
        defer { fixture.remove() }
        try await sendAlarm(using: fixture)
        let saved = try XCTUnwrap(fixture.store.load()?.chatTurns.last)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertTrue(saved.assistantMessage.hasSuffix("에 알람 맞춰뒀어."))
        XCTAssertFalse(saved.assistantMessage.contains("내일 아침 알람"))
        XCTAssertFalse(saved.assistantMessage.contains("2099-01-01T00:00:00Z"))
        let executed = await tools.executed
        XCTAssertEqual(executed.count, 1)
    }

    func testNativePermissionFailureRemainsFailedRatherThanClaimingSuccess() async throws {
        let tools = ToolReplyAdapter(data: .null, failure: .permissionDenied)
        let fixture = try ChatControllerFixture(tools: tools)
        defer { fixture.remove() }
        try await sendAlarm(using: fixture)
        let saved = try XCTUnwrap(fixture.store.load()?.chatTurns.last)
        XCTAssertEqual(saved.status, .failed)
        XCTAssertTrue(fixture.events.snapshot().contains { $0.type == "error" && $0.code == "permission_denied" })
        XCTAssertFalse(fixture.events.snapshot().contains { $0.type == "completed" })
    }

    private func sendAlarm(using fixture: ChatControllerFixture) async throws {
        await fixture.controller.initialize()
        await fixture.controller.useAlarmTestRouter()
        await fixture.runtime.setFunctionCall(.init(name: "create_alarm", argumentsJSON:
            #"{"date":"2099-01-01","hour":8,"minute":0,"label":"내일 아침 알람"}"#))
        await fixture.controller.send(json: fixture.request("tool-reply", "알람 맞춰 줘", allowedTools: [.createAlarm]))
    }
}

private extension ChatSessionController {
    func useAlarmTestRouter() { nativeToolRouter = AlarmReplyRouter() }
}

private struct AlarmReplyRouter: NativeToolRouting {
    func route(_ utterance: String) -> NativeToolRoute { .tool(.createAlarm) }
}

private actor ToolReplyAdapter: ChatPlatformTools {
    nonisolated let supportedTools: Set<NativeToolKind> = [.createAlarm]
    nonisolated let unsupportedMessage = "Unsupported test tool"
    let data: JSONValue
    let failure: NativeToolErrorCode?
    var executed: [ValidatedToolProposal] = []
    init(data: JSONValue, failure: NativeToolErrorCode? = nil) {
        self.data = data
        self.failure = failure
    }
    func enrich(_ base: UserProfileContext, allowedTools: Set<NativeToolKind>) -> UserProfileContext { base }
    func confirm(_ draft: NativeToolProposal) -> NativeToolProposal { draft }
    func cancelConfirmation() {}
    func execute(_ proposal: ValidatedToolProposal) throws -> JSONValue {
        executed.append(proposal)
        if let failure { throw failure }
        return data
    }
}

private final class ToolReplyLogs: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func snapshot() -> [String] { lock.withLock { lines } }
}
