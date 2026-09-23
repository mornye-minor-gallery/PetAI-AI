import Foundation

public enum ChatDataExportError: Error, Equatable {
    case invalidMemory(String)
}

/// A portable view of retained data, independent of the checkpoint and SQLite schemas.
/// Recent turns have no character identifier in the current device-local checkpoint.
public struct ChatDataExport: Codable, Sendable {
    public struct RecentTurn: Codable, Sendable {
        public let requestID: String
        public let userMessage: String
        public let assistantMessage: String
        public let status: ChatTurn.Status
    }

    public struct LongTermMemory: Codable, Sendable {
        public let observationID: String
        public let sourceTurnID: String
        public let characterID: String
        public let userMessage: String
        public let labels: [MemoryLabel]
        public let occurredAt: Date
    }

    public let formatVersion: Int
    public let exportedAt: Date
    public let recentTurns: [RecentTurn]
    public let longTermMemories: [LongTermMemory]

    public init(recentTurns: [ChatTurn], activeMemories: [MemoryObservation], exportedAt: Date = Date()) throws {
        if let invalid = activeMemories.first(where: { $0.state != .active || $0.labels.isEmpty }) {
            throw ChatDataExportError.invalidMemory(invalid.id)
        }
        formatVersion = 1
        self.exportedAt = exportedAt
        self.recentTurns = recentTurns.map {
            RecentTurn(requestID: $0.requestID, userMessage: $0.userMessage,
                assistantMessage: $0.assistantMessage, status: $0.status)
        }
        longTermMemories = activeMemories.map {
            LongTermMemory(observationID: $0.id, sourceTurnID: $0.turnID,
                characterID: $0.scope.characterID, userMessage: $0.rawText,
                labels: $0.labels, occurredAt: $0.occurredAt)
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
