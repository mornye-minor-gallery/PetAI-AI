import Foundation

public struct NaivePreferenceEventClassifier:
    MemoryObservationClassifying,
    Sendable
{
    public let version = "naive-keyword-ko-v1"

    private static let preferenceSignals = [
        "좋아",
        "싫어",
        "선호",
        "취향",
        "최애",
        "마음에 들어",
        "즐겨",
        "못 먹",
        "못 마셔",
    ]

    private static let eventSignals = [
        "다녀왔",
        "갔어",
        "왔어",
        "만났",
        "시작했",
        "끝냈",
        "완료했",
        "샀어",
        "구매했",
        "예약했",
        "합격했",
        "실패했",
        "성공했",
        "헤어졌",
    ]

    private static let questionSignals = [
        "?",
        "뭐",
        "무엇",
        "어디",
        "언제",
        "누구",
        "어떻게",
        "왜",
        "기억나",
    ]

    public init() {}

    public func classify(_ text: String) async throws -> Set<MemoryLabel> {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
            .lowercased()

        guard !normalized.isEmpty else {
            return []
        }
        guard
            !Self.questionSignals.contains(where: normalized.contains)
        else {
            return []
        }

        var labels: Set<MemoryLabel> = []
        if Self.preferenceSignals.contains(where: normalized.contains) {
            labels.insert(.preference)
        }
        if Self.eventSignals.contains(where: normalized.contains) {
            labels.insert(.event)
        }
        return labels
    }
}
