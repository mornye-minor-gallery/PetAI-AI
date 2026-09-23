import Foundation

public enum DialogueSessionError: Error, Equatable {
    case invalidCheckpoint, invalidRequestID, invalidExchange, activeRequest, staleSnapshot, conflictingCommit, counterOverflow
}

/// A request's prompt is captured before its user message enters recent history.
public struct DialogueSessionSnapshot: Equatable, Sendable, Encodable {
    public let requestID: String
    public let history: [RoutedPersonaSessionContext.Turn]
    public let completedUserMessages: Int
    public let completedMessages: Int
    public let visibleMessages: Int
    public let currentUserMessageNumber: Int
    public let currentMessageNumber: Int
    public let worldInfoState: WorldInfoState
    public let worldInfoText: WorldInfoTextContext
    fileprivate let epoch: UUID
    fileprivate let revision: Int
}

/// Recent request turns are authoritative. Visible-message and completed-exchange
/// clocks differ because an interrupted answer is context, not a successful reply.
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
    private var retainedTurns: [ChatTurn]
    private var activeTurn: ChatTurn?
    public var chatTurns: [ChatTurn] {
        guard maximumTurnCount > 0 else { return [] }
        return Array((retainedTurns + (activeTurn.map { [$0] } ?? [])).suffix(maximumTurnCount))
    }
    /// The current user's message is excluded; the composer receives it separately.
    public var turns: [Turn] { retainedTurns.flatMap(\.visibleMessages) }
    public private(set) var visibleUserMessages: Int
    public private(set) var visibleMessages: Int
    public private(set) var completedUserMessages: Int
    public private(set) var completedMessages: Int
    public private(set) var worldInfoState = WorldInfoState()
    public private(set) var worldInfoText = WorldInfoTextContext()
    private var epoch = UUID()
    private var revision = 0
    private var lastCommit: Commit?
    private var lastFinishedTurn: ChatTurn?
    private var lastFinishedWorldInfo: WorldInfoTransaction?

    /// Supplied fixture messages are counted before request-level retention.
    public init(maximumTurnCount: Int = SLMConfiguration.production.persona.recentTurnLimit,
                turns: [Turn] = [], worldInfoState: WorldInfoState = .init(), worldInfoText: WorldInfoTextContext = .init()) {
        self.worldInfoState = worldInfoState; self.worldInfoText = worldInfoText
        self.maximumTurnCount = max(0, maximumTurnCount)
        retainedTurns = Array(Self.groupCompletedMessages(turns).suffix(max(0, maximumTurnCount)))
        activeTurn = nil
        visibleUserMessages = turns.filter { $0.role == .user }.count
        visibleMessages = turns.count
        completedUserMessages = visibleUserMessages
        completedMessages = visibleMessages
    }

    public init(checkpoint: DialogueSessionCheckpoint) throws {
        guard checkpoint.maximumTurnCount >= 0,
              checkpoint.completedUserMessages >= 0,
              checkpoint.completedMessages >= checkpoint.completedUserMessages,
              checkpoint.turns.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DialogueSessionError.invalidCheckpoint
        }
        let restored: [ChatTurn]
        let users: Int
        let messages: Int
        switch checkpoint.version {
        case 1:
            guard checkpoint.turns.count <= checkpoint.maximumTurnCount,
                  checkpoint.turns.count <= checkpoint.completedMessages,
                  checkpoint.turns.filter({ $0.role == .user }).count <= checkpoint.completedUserMessages,
                  checkpoint.turns.filter({ $0.role == .assistant }).count <= checkpoint.completedMessages - checkpoint.completedUserMessages else {
                throw DialogueSessionError.invalidCheckpoint
            }
            restored = Self.groupCompletedMessages(checkpoint.turns)
            users = checkpoint.completedUserMessages
            messages = checkpoint.completedMessages
        case 2:
            guard let chatTurns = checkpoint.chatTurns,
                  let visibleUsers = checkpoint.visibleUserMessages,
                  let visibleMessages = checkpoint.visibleMessages,
                  chatTurns.count <= checkpoint.maximumTurnCount,
                  chatTurns.allSatisfy({ $0.status != .inProgress && !$0.requestID.isEmpty &&
                      (!$0.userMessage.isEmpty || !$0.assistantMessage.isEmpty) }),
                  chatTurns.flatMap(\.visibleMessages) == checkpoint.turns,
                  visibleUsers >= checkpoint.completedUserMessages,
                  visibleMessages >= checkpoint.completedMessages,
                  chatTurns.filter({ !$0.userMessage.isEmpty }).count <= visibleUsers,
                  checkpoint.turns.count <= visibleMessages else {
                throw DialogueSessionError.invalidCheckpoint
            }
            restored = chatTurns
            users = visibleUsers
            messages = visibleMessages
        default:
            throw DialogueSessionError.invalidCheckpoint
        }
        maximumTurnCount = checkpoint.maximumTurnCount
        retainedTurns = restored
        activeTurn = nil
        visibleUserMessages = users
        visibleMessages = messages
        completedUserMessages = checkpoint.completedUserMessages
        completedMessages = checkpoint.completedMessages
        worldInfoState = checkpoint.worldInfoState
        worldInfoText = checkpoint.worldInfoText
    }

    public func checkpoint() -> DialogueSessionCheckpoint {
        // Ownership cannot survive process loss; persist an active turn as interrupted.
        var saved = retainedTurns
        if var activeTurn {
            activeTurn.status = .cancelled
            saved.append(activeTurn)
            saved = Array(saved.suffix(maximumTurnCount))
        }
        return .init(version: 2, maximumTurnCount: maximumTurnCount,
            turns: saved.flatMap(\.visibleMessages), completedUserMessages: completedUserMessages,
            completedMessages: completedMessages, worldInfoState: worldInfoState,
            worldInfoText: worldInfoText, chatTurns: saved,
            visibleUserMessages: visibleUserMessages, visibleMessages: visibleMessages)
    }

    public func snapshot(requestID: String) throws -> DialogueSessionSnapshot {
        guard !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DialogueSessionError.invalidRequestID
        }
        guard activeTurn == nil else { throw DialogueSessionError.activeRequest }
        guard visibleMessages < Int.max, visibleUserMessages < Int.max else {
            throw DialogueSessionError.counterOverflow
        }
        // The upcoming user request is the twentieth turn, not a twenty-first
        // turn added after twenty older ones have already entered the prompt.
        let promptHistory = retainedTurns.suffix(max(0, maximumTurnCount - 1))
            .flatMap(\.visibleMessages)
        return .init(requestID: requestID, history: promptHistory, completedUserMessages: completedUserMessages,
            completedMessages: completedMessages, visibleMessages: visibleMessages,
            currentUserMessageNumber: visibleUserMessages + 1,
            currentMessageNumber: visibleMessages + 1, worldInfoState: worldInfoState,
            worldInfoText: worldInfoText, epoch: epoch, revision: revision)
    }

    @discardableResult
    public mutating func beginRequest(requestID: String, userMessage: String) throws -> DialogueSessionSnapshot {
        let user = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { throw DialogueSessionError.invalidExchange }
        let prior = try snapshot(requestID: requestID)
        guard !retainedTurns.contains(where: { $0.requestID == requestID }),
              lastFinishedTurn?.requestID != requestID else { throw DialogueSessionError.conflictingCommit }
        guard revision < Int.max else { throw DialogueSessionError.counterOverflow }
        // Align the retained set with the prompt snapshot before EdgeMem recall.
        if maximumTurnCount > 0 && retainedTurns.count == maximumTurnCount {
            retainedTurns.removeFirst()
        }
        activeTurn = .init(requestID: requestID, userMessage: user, status: .inProgress)
        visibleUserMessages += 1
        visibleMessages += 1
        revision += 1
        lastCommit = nil
        return prior
    }

    public mutating func appendAssistantText(requestID: String, text: String) throws {
        guard var activeTurn, activeTurn.requestID == requestID else { throw DialogueSessionError.staleSnapshot }
        guard !text.isEmpty else { return }
        if activeTurn.assistantMessage.isEmpty {
            guard visibleMessages < Int.max else { throw DialogueSessionError.counterOverflow }
            visibleMessages += 1
        }
        activeTurn.assistantMessage += text
        self.activeTurn = activeTurn
    }

    @discardableResult
    public mutating func finishRequest(requestID: String, status: ChatTurn.Status,
                                       assistantMessage: String? = nil,
                                       worldInfo: WorldInfoTransaction? = nil) throws -> CommitResult {
        guard status != .inProgress else { throw DialogueSessionError.invalidExchange }
        guard var activeTurn, activeTurn.requestID == requestID else {
            if let lastFinishedTurn, lastFinishedTurn.requestID == requestID, self.activeTurn == nil {
                guard lastFinishedTurn.status == status,
                      (assistantMessage == nil || lastFinishedTurn.assistantMessage == assistantMessage),
                      lastFinishedWorldInfo == worldInfo else {
                    throw DialogueSessionError.conflictingCommit
                }
                return .alreadyCommitted
            }
            throw DialogueSessionError.staleSnapshot
        }
        let finalText = assistantMessage ?? activeTurn.assistantMessage
        if status == .completed && finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DialogueSessionError.invalidExchange
        }
        if status != .completed && worldInfo != nil { throw DialogueSessionError.invalidExchange }
        if activeTurn.assistantMessage.isEmpty && !finalText.isEmpty {
            guard visibleMessages < Int.max else { throw DialogueSessionError.counterOverflow }
            visibleMessages += 1
        }
        if status == .completed {
            guard completedMessages <= Int.max - 2, completedUserMessages < Int.max else {
                throw DialogueSessionError.counterOverflow
            }
            completedUserMessages += 1
            completedMessages += 2
            if let worldInfo { worldInfoState = worldInfo.state; worldInfoText = worldInfo.text }
        }
        activeTurn.assistantMessage = finalText
        activeTurn.status = status
        self.activeTurn = nil
        retain(activeTurn)
        lastFinishedTurn = activeTurn
        lastFinishedWorldInfo = worldInfo
        return .committed
    }

    /// Evaluation callers still commit whole successful exchanges atomically.
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
        guard activeTurn == nil, snapshot.revision == revision else { throw DialogueSessionError.staleSnapshot }
        guard completedMessages <= Int.max - 2, completedUserMessages < Int.max,
              visibleMessages <= Int.max - 2, visibleUserMessages < Int.max, revision < Int.max else {
            throw DialogueSessionError.counterOverflow
        }
        appendCompletedExchange(requestID: snapshot.requestID, user: user, assistant: assistant)
        if let worldInfo { worldInfoState = worldInfo.state; worldInfoText = worldInfo.text }
        lastCommit = .init(snapshot: snapshot, user: user, assistant: assistant, worldInfo: worldInfo)
        return .committed
    }

    @discardableResult
    public mutating func appendExchange(userMessage: String, assistantMessage: String) -> Bool {
        let user = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !assistant.isEmpty, activeTurn == nil,
              completedMessages <= Int.max - 2, completedUserMessages < Int.max,
              visibleMessages <= Int.max - 2, visibleUserMessages < Int.max, revision < Int.max else { return false }
        appendCompletedExchange(requestID: "exchange-\(completedUserMessages + 1)", user: user, assistant: assistant)
        lastCommit = nil
        lastFinishedTurn = nil; lastFinishedWorldInfo = nil
        return true
    }

    public mutating func removeAll() {
        worldInfoState = .init(); worldInfoText = .init()
        retainedTurns.removeAll(); activeTurn = nil
        visibleUserMessages = 0; visibleMessages = 0
        completedUserMessages = 0; completedMessages = 0
        revision = 0; epoch = UUID()
        lastCommit = nil; lastFinishedTurn = nil; lastFinishedWorldInfo = nil
    }

    private mutating func appendCompletedExchange(requestID: String, user: String, assistant: String) {
        visibleUserMessages += 1; visibleMessages += 2
        completedUserMessages += 1; completedMessages += 2
        revision += 1
        retain(.init(requestID: requestID, userMessage: user, assistantMessage: assistant, status: .completed))
    }

    private mutating func retain(_ turn: ChatTurn) {
        guard maximumTurnCount > 0 else { return }
        retainedTurns.append(turn)
        if retainedTurns.count > maximumTurnCount { retainedTurns.removeFirst(retainedTurns.count - maximumTurnCount) }
    }

    private static func groupCompletedMessages(_ messages: [Turn]) -> [ChatTurn] {
        var result: [ChatTurn] = []
        for message in messages {
            if message.role == .user {
                result.append(.init(requestID: "restored-\(result.count)", userMessage: message.text, status: .completed))
            } else if let last = result.indices.last, result[last].assistantMessage.isEmpty {
                result[last].assistantMessage = message.text
            } else {
                // Version-1 message-level retention may start with an assistant.
                result.append(.init(requestID: "restored-\(result.count)", userMessage: "",
                                    assistantMessage: message.text, status: .completed))
            }
        }
        return result
    }
}
