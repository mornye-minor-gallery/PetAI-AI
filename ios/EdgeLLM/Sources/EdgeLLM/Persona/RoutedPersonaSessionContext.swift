import Foundation

public enum DialogueSessionError: Error, Equatable {
    case invalidRequestID, invalidExchange, staleSnapshot, conflictingCommit, counterOverflow
}

/// A pending request's clock is independent of how much text is retained.
/// Only the owning session can create a commit-capable snapshot.
public struct DialogueSessionSnapshot: Equatable, Sendable, Encodable {
    public let requestID: String
    public let history: [RoutedPersonaSessionContext.Turn]
    public let completedUserMessages: Int
    public let completedMessages: Int
    public let currentUserMessageNumber: Int
    public let currentMessageNumber: Int
    public let worldInfoState: WorldInfoState
    public let worldInfoText: WorldInfoTextContext
    fileprivate let epoch: UUID
    fileprivate let revision: Int
}

/// Value state owned by the conversation coordinator/actor, never by the composer.
public struct RoutedPersonaSessionContext: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable, Codable {
        case user = "사용자"
        case assistant = "캐릭터"
    }

    public struct Turn: Equatable, Sendable, Codable {
        public let role: Role
        public let text: String
        public init(role: Role, text: String) { self.role = role; self.text = text }
    }

    public enum CommitResult: String, Sendable { case committed, alreadyCommitted }
    private struct Commit: Equatable, Sendable {
        let snapshot: DialogueSessionSnapshot
        let user: String
        let assistant: String
        let worldInfo: WorldInfoTransaction?
    }

    public let maximumTurnCount: Int
    public private(set) var turns: [Turn]
    public private(set) var completedUserMessages: Int
    public private(set) var completedMessages: Int
    public private(set) var worldInfoState = WorldInfoState()
    public private(set) var worldInfoText = WorldInfoTextContext()
    private var epoch = UUID()
    private var revision = 0
    private var lastCommit: Commit?

    /// `turns` is the complete supplied fixture, counted before retention is applied.
    public init(maximumTurnCount: Int = SLMConfiguration.production.persona.recentMessageLimit,
                turns: [Turn] = [], worldInfoState: WorldInfoState = .init(), worldInfoText: WorldInfoTextContext = .init()) {
        self.worldInfoState = worldInfoState; self.worldInfoText = worldInfoText
        self.maximumTurnCount = max(0, maximumTurnCount)
        self.turns = Array(turns.suffix(max(0, maximumTurnCount)))
        completedUserMessages = turns.filter { $0.role == .user }.count
        completedMessages = turns.count
    }

    public func snapshot(requestID: String) throws -> DialogueSessionSnapshot {
        guard !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DialogueSessionError.invalidRequestID
        }
        guard completedMessages < Int.max, completedUserMessages < Int.max else {
            throw DialogueSessionError.counterOverflow
        }
        return .init(requestID: requestID, history: turns, completedUserMessages: completedUserMessages,
            completedMessages: completedMessages, currentUserMessageNumber: completedUserMessages + 1,
            currentMessageNumber: completedMessages + 1, worldInfoState: worldInfoState, worldInfoText: worldInfoText, epoch: epoch, revision: revision)
    }

    /// Capture once before generation; reuse that snapshot for retries. Cancellation
    /// needs no rollback because preparing a snapshot does not advance the clock.
    @discardableResult
    public mutating func commit(_ snapshot: DialogueSessionSnapshot, userMessage: String,
                                assistantMessage: String, worldInfo: WorldInfoTransaction? = nil) throws -> CommitResult {
        let user = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !assistant.isEmpty else { throw DialogueSessionError.invalidExchange }
        guard snapshot.epoch == epoch else { throw DialogueSessionError.staleSnapshot }
        if let lastCommit, lastCommit.snapshot == snapshot {
            guard lastCommit.user == user, lastCommit.assistant == assistant, lastCommit.worldInfo == worldInfo else {
                throw DialogueSessionError.conflictingCommit
            }
            return .alreadyCommitted
        }
        guard snapshot.revision == revision else { throw DialogueSessionError.staleSnapshot }
        guard completedMessages <= Int.max - 2, completedUserMessages < Int.max, revision < Int.max else {
            throw DialogueSessionError.counterOverflow
        }
        appendVisibleExchange(user: user, assistant: assistant)
        if let worldInfo { worldInfoState = worldInfo.state; worldInfoText = worldInfo.text }
        lastCommit = .init(snapshot: snapshot, user: user, assistant: assistant, worldInfo: worldInfo)
        return .committed
    }

    /// Existing app and fixture consumers already append only completed exchanges.
    /// Request-aware callers use snapshot/commit to reject stale and duplicate work.
    @discardableResult
    public mutating func appendExchange(userMessage: String, assistantMessage: String) -> Bool {
        let user = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !assistant.isEmpty else { return false }
        appendVisibleExchange(user: user, assistant: assistant)
        lastCommit = nil
        return true
    }

    public mutating func removeAll() {
        worldInfoState = .init(); worldInfoText = .init()
        turns.removeAll()
        completedUserMessages = 0
        completedMessages = 0
        revision = 0
        epoch = UUID() // A pending request from the previous session must never commit here.
        lastCommit = nil
    }

    private mutating func appendVisibleExchange(user: String, assistant: String) {
        completedUserMessages += 1
        completedMessages += 2
        revision += 1
        guard maximumTurnCount > 0 else { return }
        turns.append(.init(role: .user, text: user))
        turns.append(.init(role: .assistant, text: assistant))
        if turns.count > maximumTurnCount { turns.removeFirst(turns.count - maximumTurnCount) }
    }
}
