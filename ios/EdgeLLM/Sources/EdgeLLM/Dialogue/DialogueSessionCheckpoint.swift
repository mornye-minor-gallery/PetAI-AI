import Foundation

/// Version 2 retains interrupted turns. Pending ownership is serialized as cancelled.
public struct DialogueSessionCheckpoint: Codable, Equatable, Sendable {
    public let version: Int
    public let maximumTurnCount: Int
    public let turns: [RoutedPersonaSessionContext.Turn]
    public let completedUserMessages: Int
    public let completedMessages: Int
    public let worldInfoState: WorldInfoState
    public let worldInfoText: WorldInfoTextContext
    public let chatTurns: [ChatTurn]?
    public let visibleUserMessages: Int?
    public let visibleMessages: Int?

    public init(version: Int, maximumTurnCount: Int, turns: [RoutedPersonaSessionContext.Turn],
                completedUserMessages: Int, completedMessages: Int,
                worldInfoState: WorldInfoState, worldInfoText: WorldInfoTextContext,
                chatTurns: [ChatTurn]? = nil, visibleUserMessages: Int? = nil, visibleMessages: Int? = nil) {
        self.version = version; self.maximumTurnCount = maximumTurnCount; self.turns = turns
        self.completedUserMessages = completedUserMessages; self.completedMessages = completedMessages
        self.worldInfoState = worldInfoState; self.worldInfoText = worldInfoText
        self.chatTurns = chatTurns; self.visibleUserMessages = visibleUserMessages; self.visibleMessages = visibleMessages
    }
}

public enum DialogueSeedPolicy {
    /// The host supplies a session base seed. Retries use the same completed clock;
    /// retained history length must not influence probability or group selection.
    public static func worldInfo(base: UInt64, completedMessages: Int) -> UInt64 {
        base &+ UInt64(max(0, completedMessages))
    }
}
