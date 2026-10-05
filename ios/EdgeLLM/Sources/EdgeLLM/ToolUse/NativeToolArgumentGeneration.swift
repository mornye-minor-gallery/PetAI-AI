public enum NativeToolGenerationKind: String, CaseIterable, Sendable {
    case getStepCount = "get_step_count"
    case createAlarm = "create_alarm"
    case createTimer = "create_timer"
    case scheduleLocalNotification = "schedule_local_notification"
    case getCalendarEvents = "get_calendar_events"
    case createCalendarEvent = "create_calendar_event"

    public var nativeTool: NativeToolKind {
        switch self {
        case .getStepCount: .getStepCount
        case .createAlarm: .createAlarm
        case .createTimer: .createTimer
        case .scheduleLocalNotification: .scheduleLocalNotification
        case .getCalendarEvents: .getCalendarEvents
        case .createCalendarEvent: .createCalendarEvent
        }
    }
}

public enum NativeToolArgumentSource: Equatable, Sendable {
    case fixed(NativeToolArguments)
    case model(NativeToolGenerationKind)
}

extension NativeToolKind {
    // Parameterless tools bypass inference; model requests accept only generation kinds.
    public var argumentSource: NativeToolArgumentSource {
        switch self {
        case .getCurrentTime: .fixed(.getCurrentTime)
        case .listAlarms: .fixed(.listAlarms)
        case .getStepCount: .model(.getStepCount)
        case .createAlarm: .model(.createAlarm)
        case .createTimer: .model(.createTimer)
        case .scheduleLocalNotification: .model(.scheduleLocalNotification)
        case .getCalendarEvents: .model(.getCalendarEvents)
        case .createCalendarEvent: .model(.createCalendarEvent)
        }
    }
}
