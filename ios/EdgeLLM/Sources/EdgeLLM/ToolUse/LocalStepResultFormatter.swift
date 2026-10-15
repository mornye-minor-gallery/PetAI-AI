import Foundation

/// Phone-only recordings have an explicit coverage window, unlike a HealthKit aggregate.
enum LocalStepResultFormatter {
    static func text(_ data: [String: JSONValue], now: Date) throws -> String {
        guard case .string(let zoneID)? = data["timeZoneIdentifier"], let zone = TimeZone(identifier: zoneID),
              case .string(let from)? = data["recordedFrom"], case .string(let until)? = data["recordedUntil"] else {
            throw NativeToolResultFormattingError.invalidField("recordingCoverage")
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let format = NativeToolDateTimeFormatter(now: now, calendar: calendar)
        let period = try "\(format.string(from: from, field: "recordedFrom"))부터 \(format.string(from: until, field: "recordedUntil"))까지"
        switch data["aggregation"] {
        case .string("total"):
            return try "\(period) 이 휴대폰에 기록된 걸음은 \(count(data["totalSteps"]))걸음이야."
        case .string("daily"):
            guard case .array(let days)? = data["days"], !days.isEmpty else {
                throw NativeToolResultFormattingError.invalidField("days")
            }
            let lines = try days.map { value in
                guard case .object(let row) = value, case .string(let date)? = row["date"] else {
                    throw NativeToolResultFormattingError.invalidField("days")
                }
                return try "\(date): \(count(row["steps"]))걸음"
            }
            return "\(period) 이 휴대폰에 기록된 걸음이야.\n" + lines.joined(separator: "\n")
        default: throw NativeToolResultFormattingError.invalidField("aggregation")
        }
    }
    private static func count(_ value: JSONValue?) throws -> Int {
        guard case .number(let number) = value, number.isFinite, number >= 0,
              number <= Double(Int32.max), number.rounded(.towardZero) == number else {
            throw NativeToolResultFormattingError.invalidField("steps")
        }
        return Int(number)
    }
}
