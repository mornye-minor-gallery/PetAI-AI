import Foundation

public enum NativeToolKind: String, CaseIterable, Codable, Sendable {
    case getStepCount = "get_step_count"
    case createAlarm = "create_alarm"
    case listAlarms = "list_alarms"
    case createTimer = "create_timer"
    case scheduleLocalNotification = "schedule_local_notification"
    case getCalendarEvents = "get_calendar_events"
    case createCalendarEvent = "create_calendar_event"
}

public enum NativeToolRoute: Equatable, Sendable {
    case normal
    case tool(NativeToolKind)
    case conflict([NativeToolKind])
}

public enum StepCountAggregation: String, Codable, Sendable {
    case total
    case daily
}

public struct StepCountArguments: Codable, Equatable, Sendable {
    public let startDate: String
    public let endDate: String
    public let aggregation: StepCountAggregation

    public init(
        startDate: String,
        endDate: String,
        aggregation: StepCountAggregation
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.aggregation = aggregation
    }
}

public struct CreateAlarmArguments: Codable, Equatable, Sendable {
    public let date: String
    public let hour: Int
    public let minute: Int
    public let label: String

    public init(date: String, hour: Int, minute: Int, label: String) {
        self.date = date
        self.hour = hour
        self.minute = minute
        self.label = label
    }
}

public struct CreateTimerArguments: Codable, Equatable, Sendable {
    public let durationSeconds: Int
    public let label: String

    public init(durationSeconds: Int, label: String) {
        self.durationSeconds = durationSeconds
        self.label = label
    }
}

public struct LocalNotificationArguments: Codable, Equatable, Sendable {
    public let dateTime: String
    public let title: String
    public let body: String

    public init(dateTime: String, title: String, body: String) {
        self.dateTime = dateTime
        self.title = title
        self.body = body
    }
}

public struct CalendarQueryArguments: Codable, Equatable, Sendable {
    public let startDate: String
    public let endDate: String

    public init(startDate: String, endDate: String) {
        self.startDate = startDate
        self.endDate = endDate
    }
}

public struct CalendarEventArguments: Codable, Equatable, Sendable {
    public let title: String
    public let startDateTime: String
    public let endDateTime: String?
    public let location: String?

    public init(
        title: String,
        startDateTime: String,
        endDateTime: String? = nil,
        location: String? = nil
    ) {
        self.title = title
        self.startDateTime = startDateTime
        self.endDateTime = endDateTime
        self.location = location
    }
}

public enum NativeToolArguments: Codable, Equatable, Sendable {
    case getStepCount(StepCountArguments)
    case createAlarm(CreateAlarmArguments)
    case listAlarms
    case createTimer(CreateTimerArguments)
    case scheduleLocalNotification(LocalNotificationArguments)
    case getCalendarEvents(CalendarQueryArguments)
    case createCalendarEvent(CalendarEventArguments)

    public var tool: NativeToolKind {
        switch self {
        case .getStepCount: .getStepCount
        case .createAlarm: .createAlarm
        case .listAlarms: .listAlarms
        case .createTimer: .createTimer
        case .scheduleLocalNotification: .scheduleLocalNotification
        case .getCalendarEvents: .getCalendarEvents
        case .createCalendarEvent: .createCalendarEvent
        }
    }
}

public struct NativeToolProposal: Codable, Equatable, Sendable {
    public let requestID: String
    public let tool: NativeToolKind
    public let arguments: NativeToolArguments

    public init(
        requestID: String,
        tool: NativeToolKind,
        arguments: NativeToolArguments
    ) {
        self.requestID = requestID
        self.tool = tool
        self.arguments = arguments
    }
}

public enum ValidatedToolArguments: Equatable, Sendable {
    case getStepCount(
        startDate: Date,
        inclusiveEndDate: Date,
        exclusiveEndDate: Date,
        aggregation: StepCountAggregation
    )
    case createAlarm(date: Date, label: String)
    case listAlarms
    case createTimer(durationSeconds: Int, label: String)
    case scheduleLocalNotification(
        date: Date,
        title: String,
        body: String
    )
    case getCalendarEvents(
        startDate: Date,
        inclusiveEndDate: Date,
        exclusiveEndDate: Date,
        limit: Int
    )
    case createCalendarEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?
    )
}

public struct ValidatedToolProposal: Equatable, Sendable {
    public let requestID: String
    public let tool: NativeToolKind
    public let timeZoneIdentifier: String
    public let arguments: ValidatedToolArguments

    public init(
        requestID: String,
        tool: NativeToolKind,
        timeZoneIdentifier: String,
        arguments: ValidatedToolArguments
    ) {
        self.requestID = requestID
        self.tool = tool
        self.timeZoneIdentifier = timeZoneIdentifier
        self.arguments = arguments
    }
}

public enum NativeToolExecutionStatus: String, Codable, Sendable {
    case success
    case failure
    case cancelled
}

public enum NativeToolErrorCode: String, Codable, Error, Sendable {
    case permissionDenied = "permission_denied"
    case dataUnavailable = "data_unavailable"
    case invalidArguments = "invalid_arguments"
    case unsupportedRange = "unsupported_range"
    case pastSchedule = "past_schedule"
    case cancelledByUser = "cancelled_by_user"
    case nativeFailure = "native_failure"
    case resultTooLarge = "result_too_large"
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported JSON value."
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct NativeToolExecutionEnvelope: Codable, Equatable, Sendable {
    public let requestID: String
    public let tool: NativeToolKind
    public let status: NativeToolExecutionStatus
    public let data: JSONValue?
    public let errorCode: NativeToolErrorCode?

    public init(
        requestID: String,
        tool: NativeToolKind,
        status: NativeToolExecutionStatus,
        data: JSONValue? = nil,
        errorCode: NativeToolErrorCode? = nil
    ) {
        self.requestID = requestID
        self.tool = tool
        self.status = status
        self.data = data
        self.errorCode = errorCode
    }
}

public enum UnityToolLifecycleState: String, Codable, Sendable {
    case proposalReady = "tool_proposal_ready"
    case awaitingConfirmation = "awaiting_confirmation"
    case running = "tool_running"
    case completed = "tool_completed"
    case cancelled = "tool_cancelled"
    case failed = "tool_failed"
}

public struct UnityToolStateEvent: Codable, Equatable, Sendable {
    public let state: UnityToolLifecycleState
    public let requestID: String
    public let tool: NativeToolKind
    public let errorCode: NativeToolErrorCode?

    public init(
        state: UnityToolLifecycleState,
        requestID: String,
        tool: NativeToolKind,
        errorCode: NativeToolErrorCode? = nil
    ) {
        self.state = state
        self.requestID = requestID
        self.tool = tool
        self.errorCode = errorCode
    }
}
