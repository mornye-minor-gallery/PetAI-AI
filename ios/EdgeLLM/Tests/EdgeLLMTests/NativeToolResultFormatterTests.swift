import Foundation
import Testing
@testable import EdgeLLM

@Test
func stepCountResultFormatterProducesUserVisibleKoreanText() throws {
    let formatter = NativeToolResultFormatter()
    let envelope = NativeToolExecutionEnvelope(
        requestID: "steps-1",
        tool: .getStepCount,
        status: .success,
        data: .object([
            "aggregation": .string("total"),
            "totalSteps": .number(12_345),
        ])
    )

    #expect(
        try formatter.visibleText(for: envelope)
            == "해당 기간에는 총 12345걸음을 걸었어요."
    )
}

@Test
func alarmKitResultsProduceStableVisibleText() throws {
    let formatter = fixedToolFormatter(now: "2026-08-04T12:00:00Z")
    let alarm = NativeToolExecutionEnvelope(
        requestID: "alarm",
        tool: .createAlarm,
        status: .success,
        data: .object([
            "label": .string("기상"),
            "scheduledAt": .string("2026-08-05T07:00:00+09:00"),
        ])
    )
    let timer = NativeToolExecutionEnvelope(
        requestID: "timer",
        tool: .createTimer,
        status: .success,
        data: .object([
            "label": .string("스트레칭"),
            "durationSeconds": .number(10),
        ])
    )
    let emptyList = NativeToolExecutionEnvelope(
        requestID: "list",
        tool: .listAlarms,
        status: .success,
        data: .object(["alarms": .array([])])
    )

    #expect(
        try formatter.visibleText(for: alarm)
            == "알겠어. 내일 오전 7시에 알람 맞춰뒀어."
    )
    #expect(
        try formatter.visibleText(for: timer)
            == "10초 타이머 시작했어."
    )
    #expect(
        try formatter.visibleText(for: emptyList)
            == "설정된 PetAI 알람이나 타이머가 없어요."
    )
}

@Test
func localNotificationResultsProduceStableVisibleText() throws {
    let envelope = NativeToolExecutionEnvelope(
        requestID: "notification",
        tool: .scheduleLocalNotification,
        status: .success,
        data: .object([
            "notificationId": .string(
                "local-notification-notification"
            ),
            "scheduledAt": .string("2026-08-05T15:00:00+09:00"),
        ])
    )

    #expect(
        try fixedToolFormatter(now: "2026-08-05T00:00:00Z").visibleText(for: envelope)
            == "오늘 오후 3시에 알려줄게."
    )
}

@Test
func calendarResultsProduceStableVisibleText() throws {
    let formatter = fixedToolFormatter(now: "2026-08-05T00:00:00Z")
    let created = NativeToolExecutionEnvelope(
        requestID: "calendar-create",
        tool: .createCalendarEvent,
        status: .success,
        data: .object([
            "title": .string("멘토링"),
            "startDateTime": .string("2026-08-06T14:00:00+09:00"),
        ])
    )
    let queried = NativeToolExecutionEnvelope(
        requestID: "calendar-query",
        tool: .getCalendarEvents,
        status: .success,
        data: .object([
            "events": .array([
                .object([
                    "title": .string("멘토링"),
                    "startDateTime": .string(
                        "2026-08-06T14:00:00+09:00"
                    ),
                ]),
                .object([
                    "title": .string("스터디"),
                    "startDateTime": .string(
                        "2026-08-06T16:00:00+09:00"
                    ),
                ]),
            ]),
        ])
    )
    let empty = NativeToolExecutionEnvelope(
        requestID: "calendar-empty",
        tool: .getCalendarEvents,
        status: .success,
        data: .object(["events": .array([])])
    )
    let unavailable = NativeToolExecutionEnvelope(
        requestID: "calendar-unavailable",
        tool: .createCalendarEvent,
        status: .failure,
        errorCode: .dataUnavailable
    )

    #expect(
        try formatter.visibleText(for: created)
            == "내일 오후 2시에 ‘멘토링’ 일정 넣어뒀어."
    )
    #expect(
        try formatter.visibleText(for: queried)
            == "• 내일 오후 2시 멘토링\n"
                + "• 내일 오후 4시 스터디"
    )
    #expect(
        try formatter.visibleText(for: empty)
            == "해당 기간에 등록된 일정이 없어요."
    )
    #expect(
        try formatter.visibleText(for: unavailable)
            == "일정을 추가할 수 있는 기본 캘린더를 찾지 못했어요. 캘린더 설정을 확인해 주세요."
    )
}

@Test
func stepCountFormatterDoesNotClaimPermissionWasDenied() throws {
    let envelope = NativeToolExecutionEnvelope(
        requestID: "steps-unavailable",
        tool: .getStepCount,
        status: .failure,
        errorCode: .dataUnavailable
    )

    #expect(
        try NativeToolResultFormatter().visibleText(for: envelope)
            == "걸음 수 데이터를 확인할 수 없어요. 건강 앱에서 접근 권한과 데이터 상태를 확인해 주세요."
    )
}

@Test(arguments: [
    ("2026-10-02T14:59:00Z", "오늘 오후 11시 59분"),
    ("2026-10-02T15:00:00Z", "내일 오전 12시"),
    ("2026-10-02T23:00:00Z", "내일 오전 8시"),
    ("2026-10-03T03:05:00.123Z", "내일 오후 12시 5분"),
    ("2026-10-03T08:00:00-07:00", "10월 4일 오전 12시"),
    ("2027-02-01T00:00:00Z", "2027년 2월 1일 오전 9시"),
])
func nativeToolAlarmUsesLocalCalendarDays(_ timestamp: String, _ expected: String) throws {
    let envelope = alarmResult(timestamp)
    let formatter = fixedToolFormatter()
    #expect(try formatter.visibleText(for: envelope) == "알겠어. \(expected)에 알람 맞춰뒀어.")
    #expect(envelope.data == .object([
        "label": .string("내일 아침 알람"), "scheduledAt": .string(timestamp),
    ]))
}

@Test(arguments: [
    ("2026-03-08T08:30:00Z", "2026-03-09T07:15:00Z", "내일 오전 12시 15분"),
    ("2026-11-01T07:30:00Z", "2026-11-02T08:15:00Z", "내일 오전 12시 15분"),
    ("2026-10-03T06:59:00Z", "2026-10-03T07:00:00Z", "내일 오전 12시"),
    ("2026-12-31T20:00:00Z", "2027-01-01T16:00:00Z", "내일 오전 8시"),
])
func nativeToolAlarmHonorsDeviceTimezoneAndDaylightSaving(
    _ now: String, _ timestamp: String, _ expected: String
) throws {
    let formatter = fixedToolFormatter(now: now, timeZone: "America/Los_Angeles")
    #expect(try formatter.visibleText(for: alarmResult(timestamp))
        == "알겠어. \(expected)에 알람 맞춰뒀어.")
}

@Test(arguments: [(600.0, "10분"), (3_723.0, "1시간 2분 3초"), (86_400.0, "24시간")])
func nativeToolTimerUsesReadableDuration(_ seconds: Double, _ expected: String) throws {
    let envelope = NativeToolExecutionEnvelope(requestID: "timer", tool: .createTimer,
        status: .success, data: .object([
            "label": .string("타이머"), "durationSeconds": .number(seconds),
        ]))
    #expect(try fixedToolFormatter().visibleText(for: envelope) == "\(expected) 타이머 시작했어.")
}

private func fixedToolFormatter(
    now: String = "2026-10-02T14:59:00Z", timeZone: String = "Asia/Seoul"
) -> NativeToolResultFormatter {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone)!
    return .init(now: ISO8601DateFormatter().date(from: now)!, calendar: calendar)
}

@Test(arguments: ["", "not-a-date", "2026-10-03", "2026-10-03T08:00:00"])
func nativeToolAlarmRejectsInvalidTimestamps(_ timestamp: String) throws {
    #expect(throws: NativeToolResultFormattingError.invalidField("scheduledAt")) {
        try fixedToolFormatter().visibleText(for: alarmResult(timestamp))
    }
}

@Test
func nativeToolAlarmRejectsMissingTimestamp() throws {
    let result = NativeToolExecutionEnvelope(requestID: "alarm", tool: .createAlarm,
        status: .success, data: .object(["label": .string("아침 알람")]))
    #expect(throws: NativeToolResultFormattingError.invalidField("scheduledAt")) {
        try fixedToolFormatter().visibleText(for: result)
    }
}

@Test
func nativeToolCalendarDoesNotSilentlyDropAnInvalidEvent() throws {
    let result = NativeToolExecutionEnvelope(requestID: "calendar", tool: .getCalendarEvents,
        status: .success, data: .object(["events": .array([
            .object(["title": .string("멘토링"), "startDateTime": .string("2026-10-02T23:00:00Z")]),
            .object(["title": .string("스터디"), "startDateTime": .string("invalid")]),
        ])]))
    #expect(throws: NativeToolResultFormattingError.invalidField("startDateTime")) {
        try fixedToolFormatter().visibleText(for: result)
    }
}

@Test(arguments: [0.0, -1.0, Double.nan, Double.infinity, 10.5, 86_401.0])
func nativeToolTimerRejectsInvalidDuration(_ seconds: Double) throws {
    let result = NativeToolExecutionEnvelope(requestID: "timer", tool: .createTimer,
        status: .success, data: .object(["durationSeconds": .number(seconds)]))
    #expect(throws: NativeToolResultFormattingError.invalidField("durationSeconds")) {
        try fixedToolFormatter().visibleText(for: result)
    }
}

private func alarmResult(_ timestamp: String) -> NativeToolExecutionEnvelope {
    .init(requestID: "alarm", tool: .createAlarm, status: .success, data: .object([
        "label": .string("내일 아침 알람"), "scheduledAt": .string(timestamp),
    ]))
}
