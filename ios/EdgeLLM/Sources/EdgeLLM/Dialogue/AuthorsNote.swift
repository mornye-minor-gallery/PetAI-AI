import Foundation

public enum AuthorsNotePosition: String, Codable, Sendable {
    case beforeSystem = "before-system"
    case afterSystem = "after-system"
    case inChat = "in-chat"
}

/// Nil inherits the next layer; an explicitly empty text overrides it.
public struct AuthorsNoteOptions: Codable, Equatable, Sendable {
    public var text: String?
    public var interval: Int?
    public var position: AuthorsNotePosition?
    public var depth: Int?
    public var role: DialoguePromptRole?
    public init(text: String? = nil, interval: Int? = nil, position: AuthorsNotePosition? = nil,
                depth: Int? = nil, role: DialoguePromptRole? = nil) {
        self.text = text; self.interval = interval; self.position = position; self.depth = depth; self.role = role
    }
}

public struct AuthorsNoteCharacter: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case replace, before, after }
    public var text: String
    public var enabled: Bool?
    public var mode: Mode?
    public init(text: String, enabled: Bool = false, mode: Mode = .replace) {
        self.text = text; self.enabled = enabled; self.mode = mode
    }
}

/// The caller selects the current character. This is not a registry or retrieval engine.
public struct AuthorsNoteSettings: Codable, Equatable, Sendable {
    public var defaults: AuthorsNoteOptions?
    public var chat: AuthorsNoteOptions?
    public var character: AuthorsNoteCharacter?
    public var allowWorldInfoScan: Bool?
    public init(defaults: AuthorsNoteOptions? = nil, chat: AuthorsNoteOptions? = nil,
                character: AuthorsNoteCharacter? = nil, allowWorldInfoScan: Bool = false) {
        self.defaults = defaults; self.chat = chat; self.character = character
        self.allowWorldInfoScan = allowWorldInfoScan
    }
}

public enum AuthorsNoteError: Error, Equatable { case invalidInterval, invalidDepth, invalidMessageNumber }

public struct AuthorsNoteResolution: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case active, disabled, notDue }
    public let state: State
    public let text: String
    public let interval: Int
    public let position: AuthorsNotePosition
    public let depth: Int
    public let role: DialoguePromptRole
    public let userMessageNumber: Int
    public let allowWorldInfoScan: Bool
    // Upstream shouldWIAddPrompt is true even for empty text on an active turn.
    // WI can later compose AN-top/AN-bottom content into this resolved note.
    public var active: Bool { state == .active }
    public var insertion: DialoguePromptInsertion? {
        guard active else { return nil }
        let placement: DialoguePromptInsertion.Placement
        switch position {
        case .beforeSystem: placement = .beforeSystem
        case .afterSystem: placement = .afterSystem
        case .inChat: placement = .inChat
        }
        return .init(id: "authorsNote", source: .authorsNote, text: text,
            placement: placement, role: role, depth: depth)
    }
}

/// Behavior port of pinned SillyTavern loadSettings/setFloatingPrompt; see README.
/// This phase resolves settings and schedule only. Placement and native roles belong to the composer.
public enum AuthorsNoteResolver {
    public static func resolve(_ settings: AuthorsNoteSettings, userMessageNumber: Int) throws -> AuthorsNoteResolution {
        let interval = settings.chat?.interval ?? settings.defaults?.interval ?? 1
        let depth = settings.chat?.depth ?? settings.defaults?.depth ?? 4
        guard interval >= 0 else { throw AuthorsNoteError.invalidInterval }
        guard (0...10_000).contains(depth) else { throw AuthorsNoteError.invalidDepth }
        guard userMessageNumber >= 0 else { throw AuthorsNoteError.invalidMessageNumber }
        let count = interval == 1 ? 1 : userMessageNumber
        let state: AuthorsNoteResolution.State = interval == 0 || count == 0 ? .disabled
            : (count % interval == 0 ? .active : .notDue)
        var text = ""
        if state == .active {
            text = settings.chat?.text ?? settings.defaults?.text ?? ""
            if let character = settings.character, character.enabled == true {
                switch character.mode ?? .replace {
                case .replace: text = character.text
                case .before: text = character.text + "\n" + text
                case .after: text += "\n" + character.text
                }
            }
        }
        return .init(state: state, text: text, interval: interval,
            position: settings.chat?.position ?? settings.defaults?.position ?? .inChat,
            depth: depth, role: settings.chat?.role ?? settings.defaults?.role ?? .system,
            userMessageNumber: userMessageNumber, allowWorldInfoScan: settings.allowWorldInfoScan ?? false)
    }
}
