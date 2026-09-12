import Foundation

/// Local-only projection of an executed, user-confirmed HealthKit query. Never
/// construct this from assistant text, a proposal, or permission status alone.
public struct HomeStepObservation: Encodable, Equatable, Sendable {
    public let schemaVersion = 1
    public let source = "healthkit"
    // A decimal string distinguishes an explicit zero from a missing JsonUtility int.
    public let steps: String
    public let localDate: String
    public let dayStartUnixSeconds: Int64
    public let dayEndUnixSeconds: Int64
    public let observedAtUnixSeconds: Int64
    public let utcOffsetSeconds: Int

    public static func make(
        envelope: NativeToolExecutionEnvelope,
        proposal: ValidatedToolProposal,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> Self? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        guard
            envelope.status == .success,
            envelope.tool == .getStepCount,
            proposal.tool == .getStepCount,
            !envelope.requestID.isEmpty,
            envelope.requestID == proposal.requestID,
            proposal.timeZoneIdentifier == timeZone.identifier,
            case .getStepCount(let start, let end, let exclusiveEnd, .total) = proposal.arguments,
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
            start == today, end == today, exclusiveEnd == tomorrow,
            case .object(let data)? = envelope.data,
            case .string("total")? = data["aggregation"],
            case .number(let count)? = data["totalSteps"],
            count.isFinite, count >= 0, count <= Double(Int32.max),
            count.rounded(.towardZero) == count
        else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: today)
        guard data["startDate"] == .string(date), data["endDate"] == .string(date)
        else { return nil }

        return Self(
            steps: String(Int(count)),
            localDate: date,
            dayStartUnixSeconds: Int64(today.timeIntervalSince1970),
            dayEndUnixSeconds: Int64(tomorrow.timeIntervalSince1970),
            observedAtUnixSeconds: Int64(now.timeIntervalSince1970),
            utcOffsetSeconds: timeZone.secondsFromGMT(for: now)
        )
    }
}
