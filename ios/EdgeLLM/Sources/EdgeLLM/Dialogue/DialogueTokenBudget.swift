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

    public init(memoryTokens: Int, contextTokens: Int, outputTokens: Int) {
        self.memoryTokens = memoryTokens
        self.contextTokens = contextTokens
        self.outputTokens = outputTokens
    }

    public static func loadProductionDefaults(data: Data) throws -> Self {
        let document = try JSONDecoder().decode(RuntimeDefaultsDocument.self, from: data)
        guard document.version == 1 else { throw RuntimeDefaultsError.unsupportedVersion(document.version) }
        let budget = Self(memoryTokens: document.promptBudget.memoryTokens,
                          contextTokens: document.runtime.maxNumTokens,
                          outputTokens: document.promptBudget.outputTokens)
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
        enum CodingKeys: String, CodingKey {
            case memoryTokens = "memory_tokens"
            case outputTokens = "output_tokens"
        }
    }
    let version: Int
    let runtime: Runtime
    let promptBudget: PromptBudget
    enum CodingKeys: String, CodingKey { case version, runtime; case promptBudget = "prompt_budget" }
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
            context.randomSeed = DialogueSeedPolicy.worldInfo(base: context.randomSeed,
                completedMessages: input.session?.completedMessages ?? max(0, context.messageNumber - 1))
            context.contextTokens = tokenBudget.contextTokens
            context.characterName = input.profile.characterName
            if context.scanFields["characterDescription"] == nil { context.scanFields["characterDescription"] = input.persona.core }
            if context.scanFields["scenario"] == nil { context.scanFields["scenario"] = input.activeCard ?? "" }
            if context.scanFields["personaDescription"] == nil { context.scanFields["personaDescription"] = input.profile.promptSection() }
            let text = authoredTextContext(input, tokenBudget: tokenBudget)
            let selected = try await WorldInfoEngine.select(settings: settings, messages: messages, note: note, measurer: measurer,
                context: context, state: input.session?.worldInfoState ?? .init(), textContext: text)
            worldInfo = WorldInfoPromptProjection(selection: selected, note: note)
        } else { worldInfo = nil }
        let memory = try await DialogueMemoryContext.prepare(
            input.memories, tokenBudget: tokenBudget.memoryTokens, measurer: measurer)
        guard let memoryTokens = memory.tokens else { throw DialogueTokenBudgetError.invalidMeasurement }
        let prepared = try assemble(input: input, policy: policy, memory: memory, memoryByteBudget: nil,
            note: note, worldInfo: worldInfo, authoredContext: authoredTextContext(input, tokenBudget: tokenBudget))
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
