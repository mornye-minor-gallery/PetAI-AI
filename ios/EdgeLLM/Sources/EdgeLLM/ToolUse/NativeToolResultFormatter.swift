import Foundation

public struct NativeToolResultFormatter: Sendable {
    public init() {}

    public func visibleText(
        for envelope: NativeToolExecutionEnvelope
    ) -> String {
        guard envelope.status == .success else {
            if envelope.errorCode == .dataUnavailable {
                return "걸음 수 데이터를 확인할 수 없어요. 건강 앱에서 접근 권한과 데이터 상태를 확인해 주세요."
            }
            return "요청을 처리하지 못했어요. 다시 시도해 주세요."
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
