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

    public struct Conversation: Codable, Sendable {
        public let characterID: String
        public let recentEntries: [RecentEntry]
        public let sessionSummary: String?
    }

    public let formatVersion: Int
    public let exportedAt: Date
    public let conversations: [Conversation]
    public let longTermMemories: [LongTermMemory]
    public let diaries: [DailyDiary]

    public init(sessions: [String: RoutedPersonaSessionContext], activeMemories: [MemoryObservation],
                diaries: [DailyDiary] = [], exportedAt: Date = Date()) throws {
        if let invalid = activeMemories.first(where: { $0.state != .active || $0.labels.isEmpty }) {
            throw ChatDataExportError.invalidMemory(invalid.id)
        }
        formatVersion = 5
        self.exportedAt = exportedAt
        self.diaries = diaries
        conversations = sessions.sorted { $0.key < $1.key }.map { characterID, session in
            return Conversation(characterID: characterID, recentEntries: session.recentEntries.map { entry in
                switch entry {
                case .request(let turn):
                    RecentEntry(kind: "request", id: turn.requestID, userMessage: turn.userMessage,
                        assistantMessage: turn.assistantMessage, status: turn.status, text: nil, topic: nil)
                case .homeLine(let line):
                    RecentEntry(kind: "homeLine", id: line.id, userMessage: nil,
                        assistantMessage: nil, status: nil, text: line.text, topic: line.topic)
                }
            }, sessionSummary: session.summary)
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
