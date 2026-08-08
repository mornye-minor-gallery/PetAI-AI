import Foundation

public struct LocalNotificationRequestClarifier: Sendable {
    public static let missingTimeMessage = "언제 알려드릴까요?"
    public static let missingContentMessage = "무엇을 알려드릴까요?"
    public static let missingTimeAndContentMessage =
        "언제, 무엇을 알려드릴까요?"

    public init() {}

    public func clarification(for utterance: String) -> String? {
        let normalized = utterance
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTime = contains(
            pattern:
                #"(?:오전|오후)?\s*(?:\d{1,2}|한|두|세|네|다섯|여섯|일곱|여덟|아홉|열|열한|열두)\s*(?::\s*\d{1,2}|시(?:\s*\d{1,2}\s*분)?)|(?:\d+|한|두|세|네|다섯|여섯|일곱|여덟|아홉|열)\s*(?:초|분|시간)\s*(?:뒤|후)|정오|자정"#,
            in: normalized
        )
        let hasContent = !contentCandidate(from: normalized).isEmpty

        switch (hasTime, hasContent) {
        case (false, false):
            return Self.missingTimeAndContentMessage
        case (false, true):
            return Self.missingTimeMessage
        case (true, false):
            return Self.missingContentMessage
        case (true, true):
            return nil
        }
    }

    private func contentCandidate(from text: String) -> String {
        let removablePatterns = [
            #"(?:오늘|내일|모레|글피|이번\s*주|다음\s*주)"#,
            #"(?:오전|오후)?\s*(?:\d{1,2}|한|두|세|네|다섯|여섯|일곱|여덟|아홉|열|열한|열두)\s*(?::\s*\d{1,2}|시(?:\s*\d{1,2}\s*분)?)"#,
            #"(?:\d+|한|두|세|네|다섯|여섯|일곱|여덟|아홉|열)\s*(?:초|분|시간)\s*(?:뒤|후)"#,
            #"(?:정오|자정)"#,
            #"(?:로컬\s*)?(?:알림|리마인드)"#,
            #"(?:예약|설정|등록|추가)(?:해|하)?\s*(?:줘|주세요)?"#,
            #"(?:알려|말해)\s*(?:줘|주세요)"#,
            #"(?:해|하)?\s*(?:줘|주세요)"#,
            #"[\s\p{P}\p{S}]+"#,
        ]
        let compact = removablePatterns.reduce(text) { value, pattern in
            value.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return compact.replacingOccurrences(
            of: #"^(?:에|에는|으로|로)+"#,
            with: "",
            options: .regularExpression
        )
    }

    private func contains(pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
