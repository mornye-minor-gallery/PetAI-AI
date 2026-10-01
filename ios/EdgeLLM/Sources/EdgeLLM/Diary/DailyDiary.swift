import Foundation

public struct DailyDiary: Codable, Equatable, Sendable {
    public let characterID: String
    public let localDate: String
    public let title: String
    public let body: String
    public let completedAt: Date
}

public enum DailyDiaryError: Error, LocalizedError {
    case invalidDate, invalidDraft, noMemories, busy
    public var errorDescription: String? {
        switch self {
        case .invalidDate: "날짜를 확인해 주세요."
        case .invalidDraft: "일기를 완성하지 못했어요. 다시 시도해 주세요."
        case .noMemories: "이날은 일기로 정리할 기억이 없어요."
        case .busy: "대화나 다른 일기가 끝난 뒤 다시 시도해 주세요."
        }
    }
}

public struct DailyDiaryDay: Sendable {
    public let key: String
    public let start: Date
    public let end: Date

    public init(_ key: String, timeZone: TimeZone = .current) throws {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { throw DailyDiaryError.invalidDate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: start) == year,
              calendar.component(.month, from: start) == month,
              calendar.component(.day, from: start) == day,
              let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { throw DailyDiaryError.invalidDate }
        self.key = key
        self.start = start
        self.end = end
    }
}

public struct DailyDiaryDraft: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    public static func parse(_ text: String) -> Self? {
        struct Payload: Decodable { let title: String; let body: String }
        let trimmed = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("```") {
            guard let firstNewline = trimmed.firstIndex(of: "\n"),
                  let lastNewline = trimmed.lastIndex(of: "\n"), firstNewline < lastNewline,
                  ["```", "```json"].contains(String(trimmed[..<firstNewline]).trimmingCharacters(in: .whitespacesAndNewlines)),
                  String(trimmed[trimmed.index(after: lastNewline)...]).trimmingCharacters(in: .whitespacesAndNewlines) == "```"
            else { return nil }
            json = String(trimmed[trimmed.index(after: firstNewline)..<lastNewline])
        } else {
            json = trimmed
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else { return nil }
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = payload.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = Self(title: title, body: body)
        return draft.isValid ? draft : nil
    }

    var isValid: Bool {
        !title.isEmpty && title == title.trimmingCharacters(in: .whitespacesAndNewlines)
            && title.count <= 40 && !body.isEmpty
            && body == body.trimmingCharacters(in: .whitespacesAndNewlines)
            && body.count <= 600
            && !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !body.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public enum DailyDiaryPrompt {
    public static let system = """
        다음은 사용자가 그날 남긴 기억을 일기로 정리하는 작업입니다.
        입력에 없는 사실이나 감정은 쓰지 마세요. 계획은 실제로 일어난 일로 바꾸지 마세요.
        뒤의 기억에서 앞의 계획이 취소되었다면 취소된 상태를 반영하세요.
        한국어 존댓말로 제목 한 줄과 본문 2~4문장을 작성하세요.
        오직 {"title":"...","body":"..."} 형태의 JSON만 출력하세요.
        """

    public static func select<R: RandomNumberGenerator>(
        _ observations: [MemoryObservation], using random: inout R
    ) -> [MemoryObservation] {
        Array(observations.shuffled(using: &random).prefix(10)).sorted {
            if $0.occurredAt == $1.occurredAt { return $0.id < $1.id }
            return $0.occurredAt < $1.occurredAt
        }
    }

    public static func input(localDate: String, observations: [MemoryObservation]) -> String {
        let lines = observations.enumerated().map { index, observation in
            "\(index + 1). \(observation.rawText.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return "날짜: \(localDate)\n기억:\n" + lines.joined(separator: "\n")
    }
}
