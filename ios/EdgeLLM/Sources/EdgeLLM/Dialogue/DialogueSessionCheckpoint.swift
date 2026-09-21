import Foundation

/// Completed state only. Pending request ownership never survives serialization.
/// Hosts atomically persist this together with the completed visible response.
public struct DialogueSessionCheckpoint: Codable, Equatable, Sendable {
    public let version: Int
    public let maximumTurnCount: Int
    public let turns: [RoutedPersonaSessionContext.Turn]
    public let completedUserMessages: Int
    public let completedMessages: Int
    public let worldInfoState: WorldInfoState
    public let worldInfoText: WorldInfoTextContext
}

public enum DialogueSeedPolicy {
    /// The host supplies a session base seed. Retries use the same completed clock;
    /// retained history length must not influence probability or group selection.
    public static func worldInfo(base: UInt64, completedMessages: Int) -> UInt64 {
        base &+ UInt64(max(0, completedMessages))
    }
}
