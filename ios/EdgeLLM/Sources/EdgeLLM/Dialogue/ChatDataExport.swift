import Foundation

public enum ChatDataExportError: Error, Equatable {
    case invalidMemory(String)
}

/// A portable view of retained data, independent of the checkpoint and SQLite schemas.
/// Carried topic metadata remains separate from user-visible recent speech.
public struct ChatDataExport: Codable, Sendable {
    public struct RecentEntry: Codable, Sendable {
        public let kind: String
        public let id: String
        public let userMessage: String?
        public let assistantMessage: String?
        public let status: ChatTurn.Status?
        public let text: String?
        public let topic: HomeTopicContext?
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
    public let diaries: [DailyDiary]
    public let sessionSummary: String?

    public init(recentEntries: [RecentDialogueEntry], activeMemories: [MemoryObservation],
                diaries: [DailyDiary] = [], exportedAt: Date = Date(), sessionSummary: String? = nil) throws {
        if let invalid = activeMemories.first(where: { $0.state != .active || $0.labels.isEmpty }) {
            throw ChatDataExportError.invalidMemory(invalid.id)
        }
        formatVersion = 4
        self.sessionSummary = sessionSummary
        self.exportedAt = exportedAt
        self.diaries = diaries
        self.recentEntries = recentEntries.map { entry in
            switch entry {
            case .request(let turn):
                RecentEntry(kind: "request", id: turn.requestID, userMessage: turn.userMessage,
                    assistantMessage: turn.assistantMessage, status: turn.status, text: nil, topic: nil)
            case .homeLine(let line):
                RecentEntry(kind: "homeLine", id: line.id, userMessage: nil,
                    assistantMessage: nil, status: nil, text: line.text, topic: line.topic)
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
