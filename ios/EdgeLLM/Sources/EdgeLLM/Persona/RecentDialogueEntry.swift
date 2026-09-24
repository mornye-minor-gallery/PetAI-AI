import Foundation

/// Keep authored home speech separate from ChatTurn: an empty-user request would
/// inherit request cancellation, completion clocks, and EdgeMem turn identity.
public struct HomeDialogueLine: Codable, Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public enum RecentDialogueEntry: Codable, Equatable, Sendable {
    case request(ChatTurn)
    case homeLine(HomeDialogueLine)

    public var id: String {
        switch self {
        case .request(let turn): turn.requestID
        case .homeLine(let line): line.id
        }
    }

    public var visibleMessages: [RoutedPersonaSessionContext.Turn] {
        switch self {
        case .request(let turn): turn.visibleMessages
        case .homeLine(let line): [.init(role: .assistant, text: line.text)]
        }
    }
}
