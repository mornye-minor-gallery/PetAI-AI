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
                return "걸음 수 데이터를 확인할 수 없어요. 건강 앱에서 접근 권한과 데이터 상태를 확인해 주세요."
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
                guard !alarms.isEmpty else {
                    return "설정된 PetAI 알람이나 타이머가 없어요."
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
                    return "• \(label) (\(type))"
                }
                if !lines.isEmpty {
                    return lines.joined(separator: "\n")
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
