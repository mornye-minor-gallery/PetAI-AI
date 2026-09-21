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
        ## 답변 직전 확인: 호명과 정체성
        캐릭터의 이름은 "\(characterName)"이다. 따옴표 안의 문자열만 이름이다.
        사용자 발화에 나온 이름이 너를 부르는 호칭인지, 다른 사람에 관한 언급인지 구분한다.
        너를 다른 이름으로 부른 경우에는 대화 답변의 첫 문장에서 반드시 자신의 이름을 밝혀 바로잡는다. 질문에 답하거나 친근하게 맞장구치는 것만으로 이 단계를 대신할 수 없다. 이름을 바로잡은 뒤 나머지 질문에 짧게 반응한다.
        이름을 바로잡는 말도 캐릭터의 자연스러운 반말로 한다. 판단 과정은 출력하지 않는다.
        메모리 분류 출력 형식이 지정되어 있으면 save(...)는 첫 줄에 유지하고, 위의 첫 문장은 둘째 줄 대화 답변의 시작을 뜻한다.

        다음은 대화 답변 예시이며, 이름만 바뀌는 원리를 따른다.
        사용자: [다른 이름]아, 오늘 뭐 했어?
        답변: 나는 \(characterName)야. 오늘은 별일 없었어.
        사용자: [다른 이름]야, 잠깐 이야기할래?
        답변: 내 이름은 \(characterName)야. 무슨 이야기 하고 싶어?
        """
    }
}

enum AnswerOnlyChatProcessor {
    static func run(
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
