import Foundation

/// One policy controls both prompt instructions and response interpretation.
/// The product selects its policy explicitly; evaluation callers select each condition.
public struct PersonaResponseConfiguration: Codable, Equatable, Sendable {
    /// Core and active scene rules form one persona component for ablation.
    public var includePersona: Bool
    /// Controls app-provided profile facts, not user input or recalled memory.
    public var includeSessionContext: Bool
    public var enforceCharacterName: Bool
    public var memoryClassification: Bool
    /// Both structures are active experimental conditions, not a migration path.
    public enum NameRuleStyle: String, Codable, Sendable {
        case identityStatement = "identity-statement"
        case responseAction = "response-action"
    }
    public var nameRuleStyle: NameRuleStyle?

    public static let production = Self(
        enforceCharacterName: true, nameRuleStyle: .responseAction
    )

    public init(
        includePersona: Bool = true, includeSessionContext: Bool = true,
        enforceCharacterName: Bool = false, memoryClassification: Bool = true,
        nameRuleStyle: NameRuleStyle? = nil
    ) {
        self.includePersona = includePersona
        self.includeSessionContext = includeSessionContext
        self.enforceCharacterName = enforceCharacterName
        self.memoryClassification = memoryClassification
        self.nameRuleStyle = nameRuleStyle
    }

    /// Shared wording for evaluation placements; callers must not duplicate this rule.
    public func nameInstruction(characterName: String) -> String {
        if nameRuleStyle == .identityStatement {
            return """
            ## 이름 유지
            너의 이름은 \(characterName)다. 사용자가 너를 다른 이름으로 부르면 그 이름을 자신의 이름으로 받아들이지 않는다. 자신의 이름을 짧게 알려 주거나 누구를 부른 것인지 확인한다.
            """
        }
        return """
        ## 이름 정정
        너의 이름은 "\(characterName)"이다.
        사용자가 다른 이름으로 너를 부르면 자신의 이름을 바로잡는다.
        다른 사람을 가리키는 이름은 정정하지 않는다.
        이름을 바로잡는 말은 대화 답변의 첫 문장에 쓴다.
        이름을 바로잡은 뒤 나머지 요청에 짧게 반응한다.
        save(...) 줄이 있으면 그다음 줄에서 대화를 시작한다.
        캐릭터의 반말로 답하고, 판단 과정은 쓰지 않는다.

        예:
        사용자: [다른 이름]아, 오늘 뭐 했어?
        답변: 나는 \(characterName)야. 오늘은 별일 없었어.
        """
    }
}

enum AnswerOnlyChatProcessor {
    static func run(
        isolation: isolated (any Actor)? = #isolation,
        stream: AsyncThrowingStream<String, Error>,
        receiveVisibleText: (String) async -> Void
    ) async throws -> MemoryTaggedChatOutcome {
        // This policy has no save contract: do not reinterpret text as a memory
        // decision or invoke the classification-specific retry prompt.
        let filter = DialogueTextFilter()
        var text = ""
        for try await chunk in stream {
            text += chunk
            let visible = filter.apply(to: chunk)
            if !visible.isEmpty { await receiveVisibleText(visible) }
        }
        return MemoryTaggedChatOutcome(primary: MemoryHeaderGateResult(
            decision: nil, syntax: .absent, rawText: text,
            visibleText: filter.apply(to: text), controlText: ""
        ), retry: nil)
    }
}
