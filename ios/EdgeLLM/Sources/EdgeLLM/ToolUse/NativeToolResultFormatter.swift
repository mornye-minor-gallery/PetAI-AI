import Foundation

public struct NativeToolResultFormatter: Sendable {
    public init() {}

    public func visibleText(
        for envelope: NativeToolExecutionEnvelope
    ) -> String {
        guard envelope.status == .success else {
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
