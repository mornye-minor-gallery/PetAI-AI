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
    /// The checked-in JSON is shared by the product runtime and evaluation harness.
    /// A missing or invalid resource is a packaging error and must not silently change
    /// the model's KV-cache allocation.
    public static let production: Self = {
        do { return try loadProductionDefaults() }
        catch { preconditionFailure("Invalid slm-runtime-defaults.json: \(error)") }
    }()
    public let memoryTokens: Int
    public let contextTokens: Int
    public let outputTokens: Int
    public let limits: DialoguePromptLimits?
    public let contextPolicy: DialogueContextPolicy

    // Aggregate-only budgets are used by existing evaluation conditions. Product
    // defaults always supply component limits from the shared resource.
    public init(memoryTokens: Int, contextTokens: Int, outputTokens: Int,
                limits: DialoguePromptLimits? = nil,
                contextPolicy: DialogueContextPolicy = .production) {
        self.memoryTokens = memoryTokens
        self.contextTokens = contextTokens
        self.outputTokens = outputTokens
        self.limits = limits
        self.contextPolicy = contextPolicy
    }

    enum CodingKeys: String, CodingKey { case memoryTokens, contextTokens, outputTokens, limits, contextPolicy }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        memoryTokens = try values.decode(Int.self, forKey: .memoryTokens)
        contextTokens = try values.decode(Int.self, forKey: .contextTokens)
        outputTokens = try values.decode(Int.self, forKey: .outputTokens)
        // Existing evaluation requests intentionally contain aggregate budgets only.
        limits = try values.decodeIfPresent(DialoguePromptLimits.self, forKey: .limits)
        contextPolicy = try values.decodeIfPresent(DialogueContextPolicy.self, forKey: .contextPolicy) ?? .production
        try validate()
    }

    public static func loadProductionDefaults(data: Data) throws -> Self {
        let document = try JSONDecoder().decode(RuntimeDefaultsDocument.self, from: data)
        guard document.version == 1 else { throw RuntimeDefaultsError.unsupportedVersion(document.version) }
        let budget = Self(memoryTokens: document.promptBudget.memoryTokens,
                          contextTokens: document.runtime.maxNumTokens,
                          outputTokens: document.promptBudget.outputTokens,
                          limits: document.promptBudget.limits,
                          contextPolicy: document.contextManagement)
        try budget.validate()
        return budget
    }

    public static func loadProductionDefaults() throws -> Self {
        try loadProductionDefaults(data: Data(contentsOf: productionDefaultsURL()))
    }

    private static func productionDefaultsURL() throws -> URL {
#if SWIFT_PACKAGE
        if let url = try EdgeLLMResources.bundle().url(forResource: "slm-runtime-defaults", withExtension: "json") {
            return url
        }
#endif
        for bundle in [Bundle.main, Bundle(for: RuntimeDefaultsBundleToken.self)] {
            if let url = bundle.url(forResource: "slm-runtime-defaults", withExtension: "json",
                                    subdirectory: "EdgeLLMPrompts")
                ?? bundle.url(forResource: "slm-runtime-defaults", withExtension: "json") {
                return url
            }
        }
        throw RuntimeDefaultsError.resourceMissing
    }

    func validate() throws {
        guard memoryTokens >= 0, contextTokens > 0, outputTokens > 0,
              outputTokens < contextTokens else { throw DialogueTokenBudgetError.invalidBudget }
        try limits?.validate()
        try contextPolicy.validate()
    }
}

private struct RuntimeDefaultsDocument: Decodable {
    struct Runtime: Decodable {
        let maxNumTokens: Int
        enum CodingKeys: String, CodingKey { case maxNumTokens = "max_num_tokens" }
    }
    struct PromptBudget: Decodable {
        let memoryTokens: Int
        let outputTokens: Int
        let fixedTokens: Int
        let loreTokens: Int
        let topicTokens: Int
        let stateTokens: Int
        let questionTokens: Int
        let questionCharacters: Int
        var limits: DialoguePromptLimits {
            .init(fixedTokens: fixedTokens, loreTokens: loreTokens, topicTokens: topicTokens,
                  stateTokens: stateTokens, questionTokens: questionTokens, questionCharacters: questionCharacters)
        }
        enum CodingKeys: String, CodingKey {
            case memoryTokens = "memory_tokens"
            case outputTokens = "output_tokens"
            case fixedTokens = "fixed_tokens", loreTokens = "lore_tokens", topicTokens = "topic_tokens"
            case stateTokens = "state_tokens", questionTokens = "question_tokens", questionCharacters = "question_characters"
        }
    }
    let version: Int
    let runtime: Runtime
    let promptBudget: PromptBudget
    let contextManagement: DialogueContextPolicy
    enum CodingKeys: String, CodingKey {
        case version, runtime, promptBudget = "prompt_budget", contextManagement = "context_management"
    }
}

private enum RuntimeDefaultsError: Error {
    case resourceMissing
    case unsupportedVersion(Int)
}

private final class RuntimeDefaultsBundleToken {}

public enum DialogueTokenBudgetError: Error, Equatable {
    case invalidBudget
    case invalidMeasurement
    case exceeded(input: Int, reservedOutput: Int, capacity: Int)
}

public struct DialogueContextOverflow: Error, Sendable {
    public let prepared: PreparedDialogue
    public let inputTokens: Int
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
                               measurer: any DialogueTokenMeasuring,
                               allowContextOverflow: Bool = false) async throws -> PreparedDialogue {
        try tokenBudget.validate()
        guard !measurer.identifier.isEmpty else { throw DialogueTokenBudgetError.invalidMeasurement }
        if let limits = tokenBudget.limits { try await limits.validateQuestion(input.currentMessage, measurer: measurer) }
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
            context.randomSeed = DialogueSeedPolicy.worldInfo(base: context.randomSeed,
                completedMessages: input.session?.completedMessages ?? max(0, context.messageNumber - 1))
            context.contextTokens = tokenBudget.contextTokens
            context.characterName = input.profile.characterName
            if context.scanFields["characterDescription"] == nil { context.scanFields["characterDescription"] = input.persona.core }
            if context.scanFields["scenario"] == nil { context.scanFields["scenario"] = input.activeCard ?? "" }
            if context.scanFields["personaDescription"] == nil { context.scanFields["personaDescription"] = input.profile.promptSection() }
            let text = authoredTextContext(input, tokenBudget: tokenBudget)
            let selected = try await WorldInfoEngine.select(settings: settings, messages: messages, note: note, measurer: measurer,
                context: context, state: input.session?.worldInfoState ?? .init(), textContext: text,
                absoluteTokenBudget: tokenBudget.limits?.loreTokens,
                preferredEntryIDs: input.reactionEntryID.map { [$0] } ?? [])
            worldInfo = WorldInfoPromptProjection(selection: selected, note: note)
        } else { worldInfo = nil }
        let memory = try await DialogueMemoryContext.prepare(
            input.memories, tokenBudget: tokenBudget.memoryTokens, measurer: measurer)
        guard let memoryTokens = memory.tokens else { throw DialogueTokenBudgetError.invalidMeasurement }
        let profileText: String?
        if let limits = tokenBudget.limits {
            profileText = try await input.profile.promptSection(maximumTokens: limits.stateTokens, measurer: measurer)
        } else { profileText = nil }
        let prepared = try assemble(input: input, policy: policy, memory: memory, memoryByteBudget: nil,
            note: note, worldInfo: worldInfo, authoredContext: authoredTextContext(input, tokenBudget: tokenBudget), profileText: profileText)
        if let limits = tokenBudget.limits {
            try await validateComponents(prepared, limits: limits, measurer: measurer)
        }
        let count = try await measurer.measureInput(prepared.modelInput)
        guard count >= 0 else { throw DialogueTokenBudgetError.invalidMeasurement }
        // Subtract the reservation rather than adding it to an untrusted measurement.
        guard count <= tokenBudget.contextTokens - tokenBudget.outputTokens else {
            if allowContextOverflow { throw DialogueContextOverflow(prepared: prepared, inputTokens: count) }
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

    private static func validateComponents(_ prepared: PreparedDialogue, limits: DialoguePromptLimits,
                                           measurer: any DialogueTokenMeasuring) async throws {
        let loreIDs = Set(prepared.trace.insertions.filter { $0.source == .worldInfo || $0.source == .authorsNote }.map(\.id))
        let groups: [(String, Int, [DialoguePromptSection])] = [
            ("fixed", limits.fixedTokens, prepared.tokenSections.filter { $0.cacheStability == .sessionStable || $0.id == "nameRule" }),
            ("state", limits.stateTokens, prepared.tokenSections.filter { $0.id == "profile" }),
            ("lore", limits.loreTokens, prepared.tokenSections.filter { loreIDs.contains($0.id) || $0.id == "scene" }),
            ("topic", limits.topicTokens, prepared.tokenSections.filter { $0.id == "topic" })
        ]
        for (id, maximum, parts) in groups where !parts.isEmpty {
            let count = try await measurer.countTokens(parts.map(\.text).joined(separator: "\n\n"))
            guard count >= 0 else { throw DialogueTokenBudgetError.invalidMeasurement }
            guard count <= maximum else { throw DialogueInputLimitError.component(id: id, actual: count, maximum: maximum) }
        }
    }
}
