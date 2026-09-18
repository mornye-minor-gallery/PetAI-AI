import Foundation

/// A model-specific adapter supplies measurements, while selection stays in Swift.
/// Both operations must be read-only with respect to the active conversation.
public protocol DialogueTokenMeasuring: Sendable {
    var identifier: String { get }
    func countTokens(_ text: String) async throws -> Int
    /// Includes the native chat template and any already-prefilled tokens exactly once.
    func measureInput(_ input: DialogueModelInput) async throws -> Int
}

public struct DialogueTokenBudget: Codable, Equatable, Sendable {
    /// Initial product budget, not a quality-tuned optimum.
    public static let production = Self(memoryTokens: 2_048, contextTokens: 8_096, outputTokens: 1_024)
    public let memoryTokens: Int
    public let contextTokens: Int
    public let outputTokens: Int

    public init(memoryTokens: Int, contextTokens: Int, outputTokens: Int) {
        self.memoryTokens = memoryTokens
        self.contextTokens = contextTokens
        self.outputTokens = outputTokens
    }

    func validate() throws {
        guard memoryTokens >= 0, contextTokens > 0, outputTokens > 0,
              outputTokens < contextTokens else { throw DialogueTokenBudgetError.invalidBudget }
    }
}

public enum DialogueTokenBudgetError: Error, Equatable {
    case invalidBudget
    case invalidMeasurement
    case exceeded(input: Int, reservedOutput: Int, capacity: Int)
}

extension DialogueTokenBudgetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBudget: "Invalid dialogue token budget."
        case .invalidMeasurement: "The model tokenizer returned an invalid measurement."
        case let .exceeded(input, output, capacity):
            "Dialogue input \(input) + reserved output \(output) exceeds context capacity \(capacity)."
        }
    }
}

public struct DialogueSectionTokenCount: Codable, Equatable, Sendable {
    public let id: String
    public let role: DialoguePromptRole
    /// Standalone section count: not additive and excludes the native chat template.
    public let tokens: Int
}

public struct DialogueTokenBudgetTrace: Codable, Equatable, Sendable {
    public let measurer: String
    public let memoryTokenBudget: Int
    public let memoryTokens: Int
    public let inputTokens: Int
    public let contextTokens: Int
    public let reservedOutputTokens: Int
    public let sections: [DialogueSectionTokenCount]
    public let availableOutputTokens: Int
}

extension DialoguePromptComposer {
    /// Selection and budget checks run here for both native app and evaluation adapters.
    public static func prepare(input: DialoguePromptInput,
                               policy: DialoguePromptPolicy = .production,
                               tokenBudget: DialogueTokenBudget,
                               measurer: any DialogueTokenMeasuring) async throws -> PreparedDialogue {
        try tokenBudget.validate()
        guard !measurer.identifier.isEmpty else { throw DialogueTokenBudgetError.invalidMeasurement }
        // Validate layout before spending work on asynchronous measurements.
        let note = try resolveNote(input)
        _ = try insertionLayout(input: input, policy: policy, note: note)
        let worldInfo: WorldInfoPromptProjection?
        if let settings = input.worldInfo {
            let messages = ([RoutedPersonaSessionContext.Turn(role: .user, text: input.currentMessage)]
                + input.history.reversed()).map { turn in
                guard settings.includeNames else { return turn.text }
                let name = turn.role == .user ? input.profile.userName ?? "사용자" : input.profile.characterName
                return name + ": " + turn.text
            }
            var context = input.worldInfoContext
            context.messageNumber = input.session?.currentMessageNumber ?? context.messageNumber
            context.contextTokens = tokenBudget.contextTokens
            context.characterName = input.profile.characterName
            if context.scanFields["characterDescription"] == nil { context.scanFields["characterDescription"] = input.persona.core }
            if context.scanFields["scenario"] == nil { context.scanFields["scenario"] = input.activeCard ?? "" }
            if context.scanFields["personaDescription"] == nil { context.scanFields["personaDescription"] = input.profile.promptSection() }
            var text = input.session?.worldInfoText ?? .init()
            text.user = input.profile.userName ?? "사용자"; text.char = input.profile.characterName
            text.description = context.scanFields["characterDescription"] ?? ""
            text.personality = context.scanFields["characterPersonality"] ?? ""
            text.scenario = context.scanFields["scenario"] ?? ""
            text.persona = context.scanFields["personaDescription"] ?? ""
            let selected = try await WorldInfoEngine.select(settings: settings, messages: messages, note: note, measurer: measurer,
                context: context, state: input.session?.worldInfoState ?? .init(), textContext: text)
            worldInfo = WorldInfoPromptProjection(selection: selected, note: note)
        } else { worldInfo = nil }
        let memory = try await DialogueMemoryContext.prepare(
            input.memories, tokenBudget: tokenBudget.memoryTokens, measurer: measurer)
        guard let memoryTokens = memory.tokens else { throw DialogueTokenBudgetError.invalidMeasurement }
        let prepared = try assemble(input: input, policy: policy, memory: memory, memoryByteBudget: nil,
            note: note, worldInfo: worldInfo)
        let count = try await measurer.measureInput(prepared.modelInput)
        guard count >= 0 else { throw DialogueTokenBudgetError.invalidMeasurement }
        // Subtract the reservation rather than adding it to an untrusted measurement.
        guard count <= tokenBudget.contextTokens - tokenBudget.outputTokens else {
            throw DialogueTokenBudgetError.exceeded(input: count, reservedOutput: tokenBudget.outputTokens,
                                                     capacity: tokenBudget.contextTokens)
        }
        var sections: [DialogueSectionTokenCount] = []
        for section in prepared.tokenSections {
            let tokens = section.id == "memories" ? memoryTokens : try await measurer.countTokens(section.text)
            guard tokens >= 0 else { throw DialogueTokenBudgetError.invalidMeasurement }
            sections.append(.init(id: section.id, role: section.role, tokens: tokens))
        }
        return prepared.withTokenTrace(.init(measurer: measurer.identifier,
            memoryTokenBudget: tokenBudget.memoryTokens, memoryTokens: memoryTokens,
            inputTokens: count, contextTokens: tokenBudget.contextTokens,
            reservedOutputTokens: tokenBudget.outputTokens, sections: sections,
            availableOutputTokens: tokenBudget.contextTokens - count))
    }
}
