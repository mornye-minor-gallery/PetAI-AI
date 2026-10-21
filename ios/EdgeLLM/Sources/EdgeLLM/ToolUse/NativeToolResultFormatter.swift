import Foundation

public enum NativeToolResultFormattingError: Error, Equatable, Sendable {
    case invalidField(String)
}

public struct NativeToolResultFormatter: Sendable {
    private let dateTime: NativeToolDateTimeFormatter

    public init(now: Date = Date(), calendar: Calendar = .current) {
        dateTime = NativeToolDateTimeFormatter(now: now, calendar: calendar)
    }

    public func visibleText(
        for envelope: NativeToolExecutionEnvelope
    ) throws -> String {
        guard envelope.status == .success else {
            if envelope.errorCode == .permissionDenied {
                return "권한이 허용되지 않아 요청을 실행하지 못했어요. 설정에서 권한을 확인해 주세요."
            }
            if envelope.tool == .getStepCount,
               envelope.errorCode == .dataUnavailable
            {
                return "해당 기간의 걸음 기록을 확인할 수 없어요. 걸음 기록 설정과 조회 기간을 확인해 주세요."
            }
            if envelope.tool == .createCalendarEvent,
               envelope.errorCode == .dataUnavailable
            {
                return "일정을 추가할 수 있는 기본 캘린더를 찾지 못했어요. 캘린더 설정을 확인해 주세요."
            }
            return "요청을 처리하지 못했어요. 다시 시도해 주세요."
        }

        switch envelope.tool {
        case .getCurrentTime:
            let identifier = try requiredString("timeZoneIdentifier", in: envelope.data)
            guard let zone = TimeZone(identifier: identifier) else {
                throw NativeToolResultFormattingError.invalidField("timeZoneIdentifier")
            }
            var calendar = dateTime.calendar
            calendar.timeZone = zone
            let clock = try NativeToolDateTimeFormatter(now: dateTime.now, calendar: calendar)
                .clockString(from: requiredString("currentDateTime", in: envelope.data), field: "currentDateTime")
            let ending = clock.hasSuffix("분") ? "이야" : "야"
            return "지금은 \(clock)\(ending)."

        case .createAlarm:
            let time = try formattedDate("scheduledAt", in: envelope.data)
            return "알겠어. \(time)에 알람 맞춰뒀어."

        case .createTimer:
            guard case .object(let object)? = envelope.data,
                  case .number(let seconds)? = object["durationSeconds"],
                  seconds.isFinite, (1...86_400).contains(seconds), seconds.rounded() == seconds else {
                throw NativeToolResultFormattingError.invalidField("durationSeconds")
            }
            let duration = Int(seconds)
            let parts = [(duration / 3_600, "시간"), (duration % 3_600 / 60, "분"), (duration % 60, "초")]
                .filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }
            return "\(parts.joined(separator: " ")) 타이머 시작했어."

        case .listAlarms:
            if case .object(let object)? = envelope.data,
               case .array(let alarms)? = object["alarms"]
            {
                // Android reports the live permission flag and keeps blocked records in the list
                // (the OS cancels the real schedule when permission is revoked). Without this the
                // chat would present alarms that can no longer ring as scheduled. iOS checks
                // authorization before listing and omits the field, so its text is unchanged.
                // Records are only described, never removed: the management screen still shows them.
                var permissionRevoked = false
                if case .bool(false)? = object["authorized"] { permissionRevoked = true }
                guard !alarms.isEmpty else {
                    return permissionRevoked
                        ? "설정된 PetAI 알람이나 타이머가 없어요. 알람 권한이 꺼져 있어서 새로 맞춰도 울리지 않을 수 있어요."
                        : "설정된 PetAI 알람이나 타이머가 없어요."
                }
                let lines = alarms.compactMap { value -> String? in
                    guard
                        case .object(let alarm) = value,
                        case .string(let label)? = alarm["label"],
                        case .string(let kind)? = alarm["kind"]
                    else {
                        return nil
                    }
                    let type = kind == "timer" ? "타이머" : "알람"
                    var blocked = false
                    if case .string("blocked")? = alarm["state"] { blocked = true }
                    // The flag is read live, so a record can still say "scheduled" until reconciled.
                    return permissionRevoked || blocked
                        ? "• \(label) (\(type)) — 울리지 않아요"
                        : "• \(label) (\(type))"
                }
                if !lines.isEmpty {
                    let list = lines.joined(separator: "\n")
                    return permissionRevoked
                        ? "알람 권한이 꺼져 있어서 지금은 울리지 않아요. 설정에서 권한을 켜면 다시 울려요.\n" + list
                        : list
                }
            }

        case .createCalendarEvent:
            let title = try requiredString("title", in: envelope.data)
            let time = try formattedDate("startDateTime", in: envelope.data)
            return "\(time)에 ‘\(title)’ 일정 넣어뒀어."

        case .scheduleLocalNotification:
            let time = try formattedDate("scheduledAt", in: envelope.data)
            return "\(time)에 알려줄게."

        case .getCalendarEvents:
            guard case .object(let object)? = envelope.data,
                  case .array(let events)? = object["events"] else {
                throw NativeToolResultFormattingError.invalidField("events")
            }
            guard !events.isEmpty else { return "해당 기간에 등록된 일정이 없어요." }
            return try events.map { event in
                let title = try requiredString("title", in: event)
                let time = try formattedDate("startDateTime", in: event)
                return "• \(time) \(title)"
            }.joined(separator: "\n")

        default:
            break
        }

        guard
            envelope.tool == .getStepCount,
            case .object(let object)? = envelope.data,
            case .string(let aggregation)? = object["aggregation"]
        else {
            return "요청을 완료했어요."
        }

        if object["source"] == .string("google_local_recording") {
            return try LocalStepResultFormatter.text(object, now: dateTime.now)
        }
        if aggregation == StepCountAggregation.total.rawValue,
           case .number(let total)? = object["totalSteps"]
        {
            return "해당 기간에는 총 \(Int(total.rounded()))걸음을 걸었어요."
        }

        if aggregation == StepCountAggregation.daily.rawValue,
           case .array(let days)? = object["days"]
        {
            let lines = days.compactMap { value -> String? in
                guard
                    case .object(let day) = value,
                    case .string(let date)? = day["date"],
                    case .number(let steps)? = day["steps"]
                else {
                    return nil
                }
                return "\(date): \(Int(steps.rounded()))걸음"
            }
            if !lines.isEmpty {
                return lines.joined(separator: "\n")
            }
        }

        return "걸음 수 조회를 완료했어요."
    }

    public func unformattedSuccessText(for tool: NativeToolKind) -> String {
        switch tool {
        case .createAlarm: "알람은 맞춰뒀는데, 예약 시각을 표시하지 못했어."
        case .createTimer: "타이머는 시작했는데, 설정 내용을 표시하지 못했어."
        case .createCalendarEvent: "일정은 넣어뒀는데, 내용을 표시하지 못했어."
        case .scheduleLocalNotification: "알림은 예약했는데, 예약 시각을 표시하지 못했어."
        case .getCalendarEvents: "일정은 조회했는데, 내용을 표시하지 못했어."
        default: "요청은 완료했는데, 결과를 표시하지 못했어."
        }
    }

    private func formattedDate(_ field: String, in data: JSONValue?) throws -> String {
        try dateTime.string(from: requiredString(field, in: data), field: field)
    }

    private func requiredString(_ field: String, in data: JSONValue?) throws -> String {
        guard case .object(let object)? = data, case .string(let value)? = object[field],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeToolResultFormattingError.invalidField(field)
        }
        return value
    }
}

public enum StepCountDataPolicy {
    public static func totalSteps(from value: Double?) throws -> Int {
        guard let value else {
            throw NativeToolErrorCode.dataUnavailable
        }
        return try normalizedStepCount(value)
    }

    public static func dailySteps(from values: [Double?]) throws -> [Int] {
        guard values.contains(where: { $0 != nil }) else {
            throw NativeToolErrorCode.dataUnavailable
        }
        return try values.map { value in
            guard let value else { return 0 }
            return try normalizedStepCount(value)
        }
    }

    private static func normalizedStepCount(_ value: Double) throws -> Int {
        guard
            value.isFinite,
            value >= 0,
            value <= Double(Int.max)
        else {
            throw NativeToolErrorCode.nativeFailure
        }
        return Int(value.rounded())
    }
}
