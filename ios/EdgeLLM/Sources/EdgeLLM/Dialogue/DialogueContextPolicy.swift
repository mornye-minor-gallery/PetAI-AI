import Foundation

public struct DialoguePromptLimits: Codable, Equatable, Sendable {
    public let fixedTokens: Int
    public let loreTokens: Int
    public let topicTokens: Int
    public let stateTokens: Int
    public let questionTokens: Int
    public let questionCharacters: Int

    public init(fixedTokens: Int, loreTokens: Int, topicTokens: Int, stateTokens: Int,
                questionTokens: Int, questionCharacters: Int) {
        self.fixedTokens = fixedTokens; self.loreTokens = loreTokens
        self.topicTokens = topicTokens; self.stateTokens = stateTokens
        self.questionTokens = questionTokens; self.questionCharacters = questionCharacters
    }

    func validate() throws {
        guard [fixedTokens, loreTokens, topicTokens, stateTokens, questionTokens,
               questionCharacters].allSatisfy({ $0 > 0 }) else {
            throw DialogueTokenBudgetError.invalidBudget
        }
    }

    public func validateQuestion(_ text: String, measurer: any DialogueTokenMeasuring) async throws {
        // Unicode scalars give both Swift and the Unity adapter the same counting
        // rule, including whitespace and surrogate-pair characters.
        let characters = text.unicodeScalars.count
        guard characters <= questionCharacters else {
            throw DialogueInputLimitError.characters(actual: characters, maximum: questionCharacters)
        }
        let count = try await measurer.countTokens(text)
        guard count >= 0 else { throw DialogueTokenBudgetError.invalidMeasurement }
        guard count <= questionTokens else { throw DialogueInputLimitError.tokens(actual: count, maximum: questionTokens) }
    }
}

public struct DialogueContextPolicy: Codable, Equatable, Sendable {
    public let summaryEnabled: Bool
    public let summaryTokens: Int
    public let recentTurns: Int
    public static var production: Self { DialogueTokenBudget.production.contextPolicy }

    public init(summaryEnabled: Bool, summaryTokens: Int, recentTurns: Int) {
        self.summaryEnabled = summaryEnabled
        self.summaryTokens = summaryTokens
        self.recentTurns = recentTurns
    }

    enum CodingKeys: String, CodingKey {
        case summaryEnabled = "summary_enabled", summaryTokens = "summary_tokens", recentTurns = "recent_turns"
    }

    func validate() throws {
        guard summaryTokens > 0, recentTurns >= 0 else { throw DialogueTokenBudgetError.invalidBudget }
    }
}

public enum DialogueInputLimitError: Error, Equatable, LocalizedError {
    case characters(actual: Int, maximum: Int)
    case tokens(actual: Int, maximum: Int)
    case component(id: String, actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case let .characters(actual, maximum):
            "질문이 \(actual)자로 \(maximum)자 제한을 넘었어요. 조금 줄여주세요."
        case let .tokens(actual, maximum):
            "질문이 \(actual)토큰으로 \(maximum)토큰 제한을 넘었어요. 조금 줄여주세요."
        case let .component(id, actual, maximum):
            "Prompt component \(id) uses \(actual) tokens; maximum is \(maximum)."
        }
    }
}
