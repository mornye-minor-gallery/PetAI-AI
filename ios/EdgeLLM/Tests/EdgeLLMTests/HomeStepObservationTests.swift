import Foundation
import Testing
@testable import EdgeLLM

@Suite struct HomeStepObservationTests {
    let zone = TimeZone(identifier: "Asia/Seoul")!
    var now: Date { ISO8601DateFormatter().date(from: "2026-09-11T12:00:00+09:00")! }

    func proposal(dayOffset: Int = 0, length: Int = 1,
                  aggregation: StepCountAggregation = .total,
                  zoneID: String = "Asia/Seoul") -> ValidatedToolProposal {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.date(byAdding: .day, value: dayOffset,
                                  to: calendar.startOfDay(for: now))!
        return ValidatedToolProposal(requestID: "step-query", tool: .getStepCount,
            timeZoneIdentifier: zoneID,
            arguments: .getStepCount(startDate: start,
                inclusiveEndDate: calendar.date(byAdding: .day, value: length - 1, to: start)!,
                exclusiveEndDate: calendar.date(byAdding: .day, value: length, to: start)!,
                aggregation: aggregation))
    }

    func result(count: Double = 8412, status: NativeToolExecutionStatus = .success,
                tool: NativeToolKind = .getStepCount, requestID: String = "step-query",
                date: String = "2026-09-11", aggregation: String = "total") -> NativeToolExecutionEnvelope {
        NativeToolExecutionEnvelope(requestID: requestID, tool: tool, status: status,
            data: .object(["aggregation": .string(aggregation),
                           "startDate": .string(date), "endDate": .string(date),
                           "totalSteps": .number(count)]))
    }

    @Test(arguments: [0.0, 8412.0, Double(Int32.max)])
    func encodesExplicitSuccessfulTotal(count: Double) throws {
        let value = try #require(HomeStepObservation.make(
            envelope: result(count: count), proposal: proposal(), now: now, timeZone: zone))
        #expect(value.steps == String(Int(count)))
        #expect(value.localDate == "2026-09-11")
        #expect(value.utcOffsetSeconds == 32400)
        #expect(value.dayEndUnixSeconds - value.dayStartUnixSeconds == 86400)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(json["steps"] as? String == String(Int(count)))
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["source"] as? String == "healthkit")
    }

    @Test(arguments: [-1.0, 0.5, Double.infinity, Double.nan, Double(Int32.max) + 1])
    func rejectsInvalidCounts(count: Double) {
        #expect(HomeStepObservation.make(envelope: result(count: count),
            proposal: proposal(), now: now, timeZone: zone) == nil)
    }

    @Test(arguments: [NativeToolExecutionStatus.failure, .cancelled])
    func rejectsNonSuccess(status: NativeToolExecutionStatus) {
        #expect(HomeStepObservation.make(envelope: result(status: status),
            proposal: proposal(), now: now, timeZone: zone) == nil)
    }

    @Test func rejectsMissingCountAndMismatchedProvenance() {
        let missing = NativeToolExecutionEnvelope(requestID: "step-query", tool: .getStepCount,
            status: .success, data: .object([:]))
        for envelope in [missing, result(tool: .createAlarm), result(requestID: "stale"),
                         result(date: "2026-09-10"), result(aggregation: "daily")] {
            #expect(HomeStepObservation.make(envelope: envelope,
                proposal: proposal(), now: now, timeZone: zone) == nil)
        }
    }

    @Test func rejectsNonTodayAndDailyQueries() {
        for query in [proposal(dayOffset: -1), proposal(dayOffset: 1), proposal(length: 2),
                      proposal(aggregation: .daily), proposal(zoneID: "UTC")] {
            #expect(HomeStepObservation.make(envelope: result(),
                proposal: query, now: now, timeZone: zone) == nil)
        }
    }

    @Test func midnightRolloverDiscardsFinishedPreviousDayQuery() {
        let tomorrow = now.addingTimeInterval(86400)
        #expect(HomeStepObservation.make(envelope: result(),
            proposal: proposal(), now: tomorrow, timeZone: zone) == nil)
    }

    @Test func daylightSavingDayUsesCalendarNotFixed24Hours() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        let observed = ISO8601DateFormatter().date(from: "2026-03-08T12:00:00-04:00")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ny
        let start = calendar.startOfDay(for: observed)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let query = ValidatedToolProposal(requestID: "step-query", tool: .getStepCount,
            timeZoneIdentifier: ny.identifier,
            arguments: .getStepCount(startDate: start, inclusiveEndDate: start,
                                    exclusiveEndDate: end, aggregation: .total))
        let value = try #require(HomeStepObservation.make(envelope: result(date: "2026-03-08"),
            proposal: query, now: observed, timeZone: ny))
        #expect(value.dayEndUnixSeconds - value.dayStartUnixSeconds == 23 * 3600)
    }
}
