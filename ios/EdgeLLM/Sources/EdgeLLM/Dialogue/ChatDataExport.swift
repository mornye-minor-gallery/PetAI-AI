import Foundation

public enum ChatDataExportError: Error, Equatable {
    case invalidMemory(String)
}

/// A portable view of retained data, independent of the checkpoint and SQLite schemas.
/// Recent entries have no character identifier in the current device-local checkpoint.
public struct ChatDataExport: Codable, Sendable {
    public struct RecentEntry: Codable, Sendable {
        public let kind: String
        public let id: String
        public let userMessage: String?
        public let assistantMessage: String?
        public let status: ChatTurn.Status?
        public let text: String?
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
    public let recentEntries: [RecentEntry]
    public let longTermMemories: [LongTermMemory]

    public init(recentEntries: [RecentDialogueEntry], activeMemories: [MemoryObservation], exportedAt: Date = Date()) throws {
        if let invalid = activeMemories.first(where: { $0.state != .active || $0.labels.isEmpty }) {
            throw ChatDataExportError.invalidMemory(invalid.id)
        }
        formatVersion = 2
        self.exportedAt = exportedAt
        self.recentEntries = recentEntries.map { entry in
            switch entry {
            case .request(let turn):
                RecentEntry(kind: "request", id: turn.requestID, userMessage: turn.userMessage,
                    assistantMessage: turn.assistantMessage, status: turn.status, text: nil)
            case .homeLine(let line):
                RecentEntry(kind: "homeLine", id: line.id, userMessage: nil,
                    assistantMessage: nil, status: nil, text: line.text)
            }
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
