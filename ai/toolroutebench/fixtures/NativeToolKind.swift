public enum NativeToolKind: String, CaseIterable, Codable, Sendable {
    case getStepCount = "get_step_count"
    case createAlarm = "create_alarm"
    case listAlarms = "list_alarms"
    case createTimer = "create_timer"
    case scheduleLocalNotification = "schedule_local_notification"
    case getCalendarEvents = "get_calendar_events"
    case createCalendarEvent = "create_calendar_event"
}
