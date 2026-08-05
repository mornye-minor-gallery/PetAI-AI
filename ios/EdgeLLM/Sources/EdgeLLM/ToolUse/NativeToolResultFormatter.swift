import Foundation

public struct NativeToolResultFormatter: Sendable {
    public init() {}

    public func visibleText(
        for envelope: NativeToolExecutionEnvelope
    ) -> String {
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
        case .createAlarm:
            if case .object(let object)? = envelope.data,
               case .string(let label)? = object["label"],
               case .string(let scheduledAt)? = object["scheduledAt"]
            {
                return "\(label) 알람을 \(scheduledAt)에 설정했어요."
            }

        case .createTimer:
            if case .object(let object)? = envelope.data,
               case .string(let label)? = object["label"],
               case .number(let seconds)? = object["durationSeconds"]
            {
                return "\(label) 타이머를 \(Int(seconds.rounded()))초로 시작했어요."
            }

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
            if case .object(let object)? = envelope.data,
               case .string(let title)? = object["title"],
               case .string(let startDateTime)? = object["startDateTime"]
            {
                return "\(title) 일정을 \(startDateTime)에 추가했어요."
            }

        case .getCalendarEvents:
            if case .object(let object)? = envelope.data,
               case .array(let events)? = object["events"]
            {
                guard !events.isEmpty else {
                    return "해당 기간에 등록된 일정이 없어요."
                }
                let lines = events.compactMap { value -> String? in
                    guard
                        case .object(let event) = value,
                        case .string(let title)? = event["title"],
                        case .string(let startDateTime)? =
                            event["startDateTime"]
                    else {
                        return nil
                    }
                    return "• \(startDateTime) \(title)"
                }
                if !lines.isEmpty {
                    return lines.joined(separator: "\n")
                }
            }

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
