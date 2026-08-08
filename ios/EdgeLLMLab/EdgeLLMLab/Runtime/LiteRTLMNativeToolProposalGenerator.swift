import Foundation

#if canImport(EdgeLLM)
import EdgeLLM
#endif

#if canImport(LiteRTLM)
import LiteRTLM
#endif

#if canImport(LiteRTLM) || canImport(CLiteRTLM)
enum LiteRTLMNativeToolProposalError: Error, Equatable {
    case captureAlreadyActive
    case captureNotActive
    case unexpectedTool(expected: NativeToolKind, actual: String)
    case duplicateToolCall
    case missingToolCall
}

actor LiteRTLMNativeToolCallCapture {
    static let shared = LiteRTLMNativeToolCallCapture()

    private var expectedTool: NativeToolKind?
    private var capturedCall: NativeToolFunctionCall?

    func begin(expectedTool: NativeToolKind) throws {
        guard self.expectedTool == nil else {
            throw LiteRTLMNativeToolProposalError.captureAlreadyActive
        }
        self.expectedTool = expectedTool
        capturedCall = nil
    }

    func record(name: String, argumentsJSON: Data) throws {
        guard let expectedTool else {
            throw LiteRTLMNativeToolProposalError.captureNotActive
        }
        guard name == expectedTool.rawValue else {
            throw LiteRTLMNativeToolProposalError.unexpectedTool(
                expected: expectedTool,
                actual: name
            )
        }
        guard capturedCall == nil else {
            throw LiteRTLMNativeToolProposalError.duplicateToolCall
        }
        capturedCall = NativeToolFunctionCall(
            name: name,
            argumentsJSON: argumentsJSON
        )
    }

    func finish() throws -> NativeToolFunctionCall {
        defer {
            expectedTool = nil
            capturedCall = nil
        }
        guard expectedTool != nil else {
            throw LiteRTLMNativeToolProposalError.captureNotActive
        }
        guard let capturedCall else {
            throw LiteRTLMNativeToolProposalError.missingToolCall
        }
        return capturedCall
    }

    func cancel() {
        expectedTool = nil
        capturedCall = nil
    }
}

enum LiteRTLMNativeToolFactory {
    static func makeTool(for kind: NativeToolKind) -> any Tool {
        switch kind {
        case .getStepCount: GetStepCountProposalTool()
        case .createAlarm: CreateAlarmProposalTool()
        case .listAlarms: ListAlarmsProposalTool()
        case .createTimer: CreateTimerProposalTool()
        case .scheduleLocalNotification:
            ScheduleLocalNotificationProposalTool()
        case .getCalendarEvents: GetCalendarEventsProposalTool()
        case .createCalendarEvent: CreateCalendarEventProposalTool()
        }
    }
}

private protocol ProposalCaptureTool: Tool {
    var arguments: [String: Any] { get }
}

extension ProposalCaptureTool {
    func run() async throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        try await LiteRTLMNativeToolCallCapture.shared.record(
            name: Self.name,
            argumentsJSON: data
        )
        return ["status": "proposal_captured"]
    }
}

private struct GetStepCountProposalTool: ProposalCaptureTool {
    static let name = NativeToolKind.getStepCount.rawValue
    static let description = "지정 기간의 걸음 수 조회 파라미터를 제안한다."

    @ToolParam(description: "시작일 YYYY-MM-DD")
    var startDate: String
    @ToolParam(description: "종료일 YYYY-MM-DD")
    var endDate: String
    @ToolParam(description: "total 또는 daily")
    var aggregation: String

    var arguments: [String: Any] {
        [
            "startDate": startDate,
            "endDate": endDate,
            "aggregation": aggregation,
        ]
    }
}

private struct CreateAlarmProposalTool: ProposalCaptureTool {
    static let name = NativeToolKind.createAlarm.rawValue
    static let description = "알람 생성 파라미터를 제안한다."

    @ToolParam(description: "알람 날짜 YYYY-MM-DD")
    var date: String
    @ToolParam(description: "0부터 23까지의 시")
    var hour: Int
    @ToolParam(description: "0부터 59까지의 분")
    var minute: Int
    @ToolParam(description: "짧은 알람 이름")
    var label: String

    var arguments: [String: Any] {
        [
            "date": date,
            "hour": hour,
            "minute": minute,
            "label": label,
        ]
    }
}

private struct ListAlarmsProposalTool: ProposalCaptureTool {
    static let name = NativeToolKind.listAlarms.rawValue
    static let description = "PetAI 알람 목록 조회를 제안한다."

    var arguments: [String: Any] { [:] }
}

private struct CreateTimerProposalTool: ProposalCaptureTool {
    static let name = NativeToolKind.createTimer.rawValue
    static let description = "카운트다운 타이머 파라미터를 제안한다."

    @ToolParam(description: "1부터 86400까지의 지속 시간(초)")
    var durationSeconds: Int
    @ToolParam(description: "짧은 타이머 이름")
    var label: String

    var arguments: [String: Any] {
        [
            "durationSeconds": durationSeconds,
            "label": label,
        ]
    }
}

private struct ScheduleLocalNotificationProposalTool: ProposalCaptureTool {
    static let name = NativeToolKind.scheduleLocalNotification.rawValue
    static let description = "로컬 알림 예약 파라미터를 제안한다."

    @ToolParam(description: "알림 시각 YYYY-MM-DDTHH:mm")
    var dateTime: String
    @ToolParam(description: "짧은 알림 제목")
    var title: String
    @ToolParam(description: "사용자에게 표시할 알림 본문")
    var body: String

    var arguments: [String: Any] {
        [
            "dateTime": dateTime,
            "title": title,
            "body": body,
        ]
    }
}

private struct GetCalendarEventsProposalTool: ProposalCaptureTool {
    static let name = NativeToolKind.getCalendarEvents.rawValue
    static let description = "캘린더 조회 기간을 제안한다."

    @ToolParam(description: "시작일 YYYY-MM-DD")
    var startDate: String
    @ToolParam(description: "종료일 YYYY-MM-DD")
    var endDate: String

    var arguments: [String: Any] {
        [
            "startDate": startDate,
            "endDate": endDate,
        ]
    }
}

private struct CreateCalendarEventProposalTool: ProposalCaptureTool {
    static let name = NativeToolKind.createCalendarEvent.rawValue
    static let description = "캘린더 일정 생성 파라미터를 제안한다."

    @ToolParam(description: "일정 제목")
    var title: String
    @ToolParam(description: "시작 시각 YYYY-MM-DDTHH:mm")
    var startDateTime: String
    @ToolParam(description: "선택적 종료 시각 YYYY-MM-DDTHH:mm")
    var endDateTime: String?
    @ToolParam(description: "선택적 장소")
    var location: String?

    var arguments: [String: Any] {
        var result: [String: Any] = [
            "title": title,
            "startDateTime": startDateTime,
        ]
        if let endDateTime {
            result["endDateTime"] = endDateTime
        }
        if let location {
            result["location"] = location
        }
        return result
    }
}
#endif
