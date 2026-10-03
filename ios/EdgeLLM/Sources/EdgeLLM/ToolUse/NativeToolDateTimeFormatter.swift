import Foundation

struct NativeToolDateTimeFormatter: Sendable {
    let now: Date
    let calendar: Calendar

    func string(from timestamp: String, field: String) throws -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = parser.date(from: timestamp)
        parser.formatOptions = [.withInternetDateTime]
        guard let date = fractionalDate ?? parser.date(from: timestamp) else {
            throw NativeToolResultFormattingError.invalidField(field)
        }

        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute,
              let dayDistance = calendar.dateComponents([.day],
                  from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day else {
            throw NativeToolResultFormattingError.invalidField(field)
        }

        // Calendar days, rather than elapsed seconds, preserve tomorrow across DST changes.
        let dayText: String
        switch dayDistance {
        case 0: dayText = "오늘"
        case 1: dayText = "내일"
        default:
            let yearText = year == calendar.component(.year, from: now) ? "" : "\(year)년 "
            dayText = "\(yearText)\(month)월 \(day)일"
        }
        let period = hour < 12 ? "오전" : "오후"
        let clockHour = hour % 12 == 0 ? 12 : hour % 12
        let minuteText = minute == 0 ? "" : " \(minute)분"
        return "\(dayText) \(period) \(clockHour)시\(minuteText)"
    }
}
