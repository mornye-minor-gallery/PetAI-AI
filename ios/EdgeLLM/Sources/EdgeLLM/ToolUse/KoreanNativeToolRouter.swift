import Foundation

public struct KoreanNativeToolRouter: Sendable {
    private struct Rule: Sendable {
        let tool: NativeToolKind
        let domain: String
        let request: String
    }

    private static let rules = [
        Rule(
            tool: .getStepCount,
            domain: #"걸음|보행|스텝|만\s*보"#,
            request: #"몇|얼마|알려\s*줘|보여\s*줘|조회|확인|합계"#
        ),
        Rule(
            tool: .createAlarm,
            domain: #"알람|깨워"#,
            request: #"맞춰\s*줘|설정해\s*줘|등록해\s*줘|추가해\s*줘|만들어\s*줘|깨워\s*줘"#
        ),
        Rule(
            tool: .listAlarms,
            domain: #"알람"#,
            request: #"목록|보여\s*줘|알려\s*줘|조회|확인|뭐|어떤"#
        ),
        Rule(
            tool: .createTimer,
            domain: #"타이머|카운트다운"#,
            request: #"시작|설정|맞춰\s*줘|재\s*줘|켜\s*줘"#
        ),
        Rule(
            tool: .scheduleLocalNotification,
            domain: #"알림|리마인드|라고\s*알려"#,
            request: #"예약|설정|등록|추가|알려\s*줘"#
        ),
        Rule(
            tool: .getCalendarEvents,
            domain: #"일정|캘린더|약속"#,
            request: #"알려\s*(?:줘|주고)|보여\s*(?:줘|주고)|조회|확인|뭐|어떤|있어\s*\?|있나\s*\?"#
        ),
        Rule(
            tool: .createCalendarEvent,
            domain: #"일정|캘린더|약속"#,
            request: #"잡아\s*줘|추가해\s*줘|등록해\s*줘|생성해\s*줘|만들어\s*줘|넣어\s*줘"#
        ),
    ]

    public init() {}

    public func route(_ utterance: String) -> NativeToolRoute {
        let normalized = utterance
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return .normal }

        let matches = Self.rules.compactMap { rule in
            contains(pattern: rule.domain, in: normalized)
                && contains(pattern: rule.request, in: normalized)
                ? rule.tool
                : nil
        }
        let unique = NativeToolKind.allCases.filter(matches.contains)

        switch unique.count {
        case 0: return .normal
        case 1: return .tool(unique[0])
        default: return .conflict(unique)
        }
    }

    private func contains(pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
