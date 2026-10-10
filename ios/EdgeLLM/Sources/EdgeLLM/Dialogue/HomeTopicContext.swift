import Foundation

/// Authored support belongs to the carried speech, not to a second conversation store.
public struct HomeTopicContext: Codable, Equatable, Sendable {
    public let id: String
    public let characterID: String
    public let guidance: String

    public init(id: String, characterID: String, guidance: String = "") {
        self.id = id
        self.characterID = characterID
        self.guidance = guidance
    }

    private enum CodingKeys: String, CodingKey {
        case id, characterID = "characterId", guidance
    }

    var isValid: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !characterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var promptText: String? {
        guard !guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "## 현재 화두의 보조 자료\n" + guidance
    }

    static func latest(in entries: [RecentDialogueEntry]) -> HomeTopicContext? {
        entries.compactMap { entry -> HomeDialogueLine? in
            if case .homeLine(let line) = entry { return line }
            return nil
        }.last?.topic
    }
}
