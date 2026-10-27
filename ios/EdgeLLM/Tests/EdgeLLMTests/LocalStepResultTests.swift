import Foundation
import Testing
@testable import EdgeLLM

@Suite struct LocalStepResultTests {
    let now = ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")!
    var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Seoul")!; return value }
    func data(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        ["source": .string("google_local_recording"), "aggregation": .string("total"), "totalSteps": .number(42),
         "startDate": .string("2026-10-15"), "endDate": .string("2026-10-15"), "partial": .bool(true),
         "recordedFrom": .string("2026-10-15T20:00:00+09:00"), "recordedUntil": .string("2026-10-15T21:00:00+09:00"),
         "timeZoneIdentifier": .string("Asia/Seoul")].merging(extra) { _, new in new }
    }
    func envelope(_ fields: [String: JSONValue]) -> NativeToolExecutionEnvelope {
        .init(requestID: "steps", tool: .getStepCount, status: .success, data: .object(fields))
    }
    @Test func partialResultNamesActualRecordedPeriod() throws {
        let value = try NativeToolResultFormatter(now: now, calendar: calendar).visibleText(for: envelope(data()))
        #expect(value == "오늘 오후 8시부터 오늘 오후 9시까지 이 휴대폰에 기록된 걸음은 42걸음이야.")
    }
    @Test(arguments: [-1.0, 0.5, Double.infinity, Double.nan, Double(Int32.max) + 1])
    func rejectsInvalidSDKCounts(_ count: Double) {
        #expect(throws: NativeToolResultFormattingError.self) {
            try NativeToolResultFormatter(now: now, calendar: calendar).visibleText(for: envelope(data(["totalSteps": .number(count)])))
        }
    }
    @Test func dailyResultRetainsCoverage() throws {
        let fields = data(["aggregation": .string("daily"), "days": .array([.object(["date": .string("2026-10-15"), "steps": .number(0)])])])
        let value = try NativeToolResultFormatter(now: now, calendar: calendar).visibleText(for: envelope(fields))
        #expect(value.contains("오늘 오후 8시부터 오늘 오후 9시까지")); #expect(value.contains("2026-10-15: 0걸음"))
    }
    @Test func homeRejectsPartialButAcceptsFullDayLocalRecording() throws {
        let start = calendar.startOfDay(for: now), end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let proposal = ValidatedToolProposal(requestID: "steps", tool: .getStepCount, timeZoneIdentifier: "Asia/Seoul",
            arguments: .getStepCount(startDate: start, inclusiveEndDate: start, exclusiveEndDate: end, aggregation: .total))
        #expect(HomeStepObservation.make(envelope: envelope(data()), proposal: proposal, now: now, timeZone: calendar.timeZone) == nil)
        let full = data(["partial": .bool(false), "recordedFrom": .string("2026-10-15T00:00:00+09:00")])
        #expect(HomeStepObservation.make(envelope: envelope(full), proposal: proposal, now: now, timeZone: calendar.timeZone)?.source == "google_local_recording")
        let mismatched = data(["partial": .bool(false)])
        #expect(HomeStepObservation.make(envelope: envelope(mismatched), proposal: proposal, now: now, timeZone: calendar.timeZone) == nil)
    }
}
