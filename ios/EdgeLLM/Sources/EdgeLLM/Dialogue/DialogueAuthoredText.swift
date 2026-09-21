import Foundation

extension DialoguePromptComposer {
    /// The same context feeds standalone notes and lore; enabling lore never changes macro semantics.
    static func authoredTextContext(_ input: DialoguePromptInput, tokenBudget: DialogueTokenBudget? = nil) -> WorldInfoTextContext {
        var text = input.session?.worldInfoText ?? .init()
        text.user = input.profile.userName ?? "사용자"
        text.char = input.profile.characterName
        let fields = input.worldInfoContext.scanFields
        text.description = fields["characterDescription"] ?? input.persona.core
        text.personality = fields["characterPersonality"] ?? ""
        text.scenario = fields["scenario"] ?? input.activeCard ?? ""
        text.persona = fields["personaDescription"] ?? input.profile.promptSection()
        text.regex = input.authoredText.regex
        var runtime = input.authoredText.runtime
        runtime["input"] = .string(input.currentMessage)
        runtime["messages"] = .array(input.history.map { .object(["mes": .string($0.text), "is_user": .bool($0.role == .user)]) })
        runtime["firstIncludedMessageID"] = .number(Double(max(0, (input.session?.completedMessages ?? input.history.count) - input.history.count)))
        if let tokenBudget {
            runtime["contextTokens"] = .number(Double(tokenBudget.contextTokens))
            runtime["outputTokens"] = .number(Double(tokenBudget.outputTokens))
            runtime["inputTokens"] = .number(Double(tokenBudget.contextTokens - tokenBudget.outputTokens))
        }
        text.runtime = runtime
        return text
    }
}
