import Foundation

public enum NameRulePlacement: String, Codable, Sendable, CaseIterable {
    case system
    case beforeCurrent = "before-current"
    case afterCurrent = "after-current"
}

/// A request snapshot. Composition never mutates session history or stored memories.
public struct DialoguePromptInput: Sendable {
    public let persona: RoutedPersonaPromptSet
    public let activeCard: String?
    public let profile: UserProfileContext
    public let history: [RoutedPersonaSessionContext.Turn]
    public let memories: [RetrievedMemoryObservation]
    public let currentMessage: String
    public let insertions: [DialoguePromptInsertion]
    public let session: DialogueSessionSnapshot?
    public let authorsNote: AuthorsNoteSettings?
    public let worldInfo: WorldInfoSettings?
    public let worldInfoContext: WorldInfoContext
    public let exampleDialogue: String

    public init(persona: RoutedPersonaPromptSet, activeCard: String? = nil,
                profile: UserProfileContext = .init(),
                history: [RoutedPersonaSessionContext.Turn] = [],
                memories: [RetrievedMemoryObservation] = [], currentMessage: String,
                insertions: [DialoguePromptInsertion] = [], session: DialogueSessionSnapshot? = nil,
                authorsNote: AuthorsNoteSettings? = nil, worldInfo: WorldInfoSettings? = nil,
                worldInfoContext: WorldInfoContext = .init(), exampleDialogue: String = "") {
        self.persona = persona
        self.activeCard = activeCard
        self.profile = profile
        self.history = history
        self.memories = memories
        self.currentMessage = currentMessage
        self.insertions = insertions
        self.session = session
        self.authorsNote = authorsNote
        self.worldInfo = worldInfo
        self.worldInfoContext = worldInfoContext
        self.exampleDialogue = exampleDialogue
    }
}

public struct DialoguePromptPolicy: Codable, Equatable, Sendable {
    public let persona: PersonaResponseConfiguration
    public let nameRulePlacement: NameRulePlacement
    /// Existing whole-memory-line budget, in UTF-8 bytes. Not a context token limit.
    public let memoryByteBudget: Int
    public static let production = Self()

    public init(persona: PersonaResponseConfiguration = .production,
                nameRulePlacement: NameRulePlacement = .system,
                memoryByteBudget: Int = SLMConfiguration.production.memory.promptByteBudget) {
        self.persona = persona
        self.nameRulePlacement = nameRulePlacement
        self.memoryByteBudget = memoryByteBudget
    }
}

public enum DialoguePromptError: Error, Equatable {
    case invalidMemoryByteBudget
    case inactiveNameRulePlacement
    case invalidInsertionID(String)
    case sessionHistoryMismatch, missingSessionSnapshot
    case invalidInsertionDepth(String)
}

public struct DialogueMemoryTrace: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case included, empty, budgetExceeded
    }
    public let id: String
    public let rank: Int
    public let bytes: Int
    public let reason: Reason
}

public struct DialoguePromptTrace: Codable, Equatable, Sendable {
    public let systemSections: [String]
    public let userSections: [String]
    public let systemBytes: Int
    public let userBytes: Int
    public let nameRulePlacement: NameRulePlacement
    public let nameRuleIncluded: Bool
    public let historyMessages: Int
    public let memoryByteBudget: Int?
    public let memories: [DialogueMemoryTrace]
    public let insertions: [DialogueInsertionTrace]
    public let authorsNote: AuthorsNoteResolution?
    public let worldInfo: WorldInfoTrace?
    public internal(set) var tokenBudget: DialogueTokenBudgetTrace?
    public var insertedMemoryCount: Int { memories.filter { $0.reason == .included }.count }
    public var insertedMemoryBytes: Int {
        memories.filter { $0.reason == .included }.reduce(0) { $0 + $1.bytes }
    }
}

public struct PreparedDialogue: Sendable {
    public let systemPrompt: String
    public let userPrompt: String
    /// Diagnostic views used by evaluation; generated from the same structured input.
    public let unpositionedUserPrompt: String
    public let memoryAugmentedInput: String
    public let nameInstruction: String
    /// The processor must use this policy, not a second independently selected default.
    public let responseConfiguration: PersonaResponseConfiguration
    public let trace: DialoguePromptTrace
    public internal(set) var worldInfoTransaction: WorldInfoTransaction? = nil
    let tokenSections: [DialoguePromptSection]

    public var modelInput: DialogueModelInput {
        .init(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    func withTokenTrace(_ tokenTrace: DialogueTokenBudgetTrace) -> Self {
        var updated = trace
        updated.tokenBudget = tokenTrace
        return .init(systemPrompt: systemPrompt, userPrompt: userPrompt,
            unpositionedUserPrompt: unpositionedUserPrompt, memoryAugmentedInput: memoryAugmentedInput,
            nameInstruction: nameInstruction, responseConfiguration: responseConfiguration, trace: updated, worldInfoTransaction: worldInfoTransaction, tokenSections: tokenSections)
    }
}
