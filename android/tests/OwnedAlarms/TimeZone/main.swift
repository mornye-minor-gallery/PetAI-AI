import Foundation

func scheduled(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> String {
    let value = Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    return ISO8601DateFormatter().string(from: value)
}
precondition(AndroidTimeZone.apply("Etc/UTC"))
precondition(scheduled(2026, 10, 16, 7) == "2026-10-16T07:00:00Z")
precondition(AndroidTimeZone.apply("Asia/Seoul"))
precondition(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: 1_800_000_000)) == 9 * 3600)
precondition(scheduled(2026, 10, 16, 7) == "2026-10-15T22:00:00Z")
precondition(AndroidTimeZone.apply("America/New_York"))
precondition(scheduled(2026, 10, 16, 7) == "2026-10-16T11:00:00Z")
precondition(!AndroidTimeZone.apply("Invalid/NotAZone"))
precondition(Calendar.current.timeZone.identifier == "America/New_York")
precondition(AndroidTimeZone.apply("Asia/Seoul"))
print("PASS Android host time zone: UTC, Seoul, DST zone, invalid ID and repeated updates")
