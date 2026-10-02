import Foundation

public enum DialoguePromptRole: String, Codable, Sendable {
    case system, user, assistant
}

/// Logical content, not a native role message. Main-prompt anchors order the request
/// context after history; in-chat blocks retain their requested depth. Both are folded
/// into user text. Requested roles remain metadata; no extra native turns are synthesized.
public struct DialoguePromptInsertion: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case authorsNote, worldInfo, nameRule }
    public enum Placement: String, Codable, Sendable { case beforeCurrent, afterCurrent, beforeSystem, afterSystem, inChat, beforePersona, afterPersona }

    public let id: String
    public let source: Source
    public let text: String
    public let placement: Placement
    public let role: DialoguePromptRole
    public let depth: Int?
    public let order: Int

    public init(id: String, source: Source, text: String, placement: Placement,
                role: DialoguePromptRole = .system, order: Int = 100, depth: Int? = nil) {
        self.id = id
        self.source = source
        self.text = text
        self.placement = placement
        self.role = role
        self.order = order
        self.depth = depth
    }
}

public struct DialogueInsertionTrace: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case included, empty }
    public let id: String
    public let source: DialoguePromptInsertion.Source
    public let placement: DialoguePromptInsertion.Placement
    public let requestedRole: DialoguePromptRole
    public let deliveredRole: DialoguePromptRole?
    public let depth: Int?
    public let order: Int
    public let reason: Reason
}

public struct DialogueModelInput: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable { case systemAndUserText }
    public let format: Format
    public let systemPrompt: String
    public let userPrompt: String

    public init(systemPrompt: String, userPrompt: String) {
        format = .systemAndUserText
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
    }
}

struct DialogueInsertionLayout {
    let before: [DialoguePromptSection]
    let after: [DialoguePromptSection]
    let beforePersona: [DialoguePromptSection]
    let afterPersona: [DialoguePromptSection]
    let beforeSystem: [DialoguePromptSection]
    let afterSystem: [DialoguePromptSection]
    let history: [Int: [DialoguePromptSection]]
    let trace: [DialogueInsertionTrace]

    init(_ supplied: [DialoguePromptInsertion], nameRule: DialoguePromptInsertion?, historyCount: Int = 0) throws {
        var ids = Set(["history", "memories", "currentMessage", "nameRule", "persona", "scene", "profile", "responseContract"])
        for item in supplied {
            guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.id.hasPrefix("history."),
                  ids.insert(item.id).inserted else {
                throw DialoguePromptError.invalidInsertionID(item.id)
            }
        }
        let items = (supplied + (nameRule.map { [$0] } ?? [])).enumerated().sorted {
            $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order < $1.element.order
        }.map(\.element)
        var before: [DialoguePromptSection] = []
        var after: [DialoguePromptSection] = []
        var beforePersona: [DialoguePromptSection] = []
        var afterPersona: [DialoguePromptSection] = []
        var beforeSystem: [DialoguePromptSection] = []
        var afterSystem: [DialoguePromptSection] = []
        var history: [Int: [DialoguePromptSection]] = [:]
        var trace: [DialogueInsertionTrace] = []
        for item in items {
            if item.placement == .inChat {
                guard let depth = item.depth, (0...10_000).contains(depth) else {
                    throw DialoguePromptError.invalidInsertionDepth(item.id)
                }
            }
            let empty = item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            trace.append(.init(id: item.id, source: item.source, placement: item.placement,
                requestedRole: item.role, deliveredRole: empty ? nil : .user, depth: item.depth, order: item.order,
                reason: empty ? .empty : .included))
            guard !empty else { continue }
            let section = DialoguePromptSection(id: item.id, text: item.text)
            switch item.placement {
            case .beforeCurrent: before.append(section)
            case .afterCurrent: after.append(section)
            case .beforePersona: beforePersona.append(section)
            case .afterPersona: afterPersona.append(section)
            case .beforeSystem: beforeSystem.append(section)
            case .afterSystem: afterSystem.append(section)
            case .inChat:
                // Depth counts real messages, including the pending user message.
                // Retrieved memory and other injected blocks never advance this index.
                let depth = item.depth!
                if depth == 0 { after.append(section) }
                else if depth == 1 { before.append(section) }
                else { history[max(0, historyCount + 1 - depth), default: []].append(section) }

            }
        }
        self.before = before
        self.after = after
        self.trace = trace
        self.beforePersona = beforePersona
        self.afterPersona = afterPersona
        self.beforeSystem = beforeSystem
        self.afterSystem = afterSystem
        self.history = history
    }
}
