import Foundation
import Testing
@testable import EdgeLLM

@Test
func routedPersonaRegistryLoadsFrozenResearchBytes() throws {
    let prompts = try RoutedPersonaPromptRegistry().load()

    #expect(prompts.core.contains("Elena Compact Core v2"))
    #expect(prompts.boundaryRouter.contains("BOUNDARY"))
    #expect(prompts.sceneRouter.contains("FIRST_SIGNAL"))
    #expect(prompts.sceneCards.count == 20)
    #expect(prompts.sceneCards[.general]?.card == nil)
}

@Test
func routedPersonaRegistryRejectsModifiedBytes() {
    let registry = RoutedPersonaPromptRegistry { fileName in
        Data("modified \(fileName)".utf8)
    }

    #expect(throws: RoutedPersonaPromptRegistryError.self) {
        _ = try registry.load()
    }
}

@Test
func routedPersonaParsersAcceptOneRouteAndRejectAmbiguity() {
    let parser = RoutedPersonaRouteParser()

    #expect(parser.boundary("BOUNDARY") == .boundary)
    #expect(parser.boundary("route: in_scope") == .inScope)
    #expect(parser.boundary("BOUNDARY IN_SCOPE") == nil)
    #expect(parser.boundary("설명만 출력") == nil)
    #expect(parser.boundaryOrSafeFallback("BOUNDARY") == .boundary)
    #expect(parser.boundaryOrSafeFallback("IN_SCOPE") == .inScope)
    #expect(parser.boundaryOrSafeFallback("BOUNDARY IN_SCOPE") == .boundary)
    #expect(parser.boundaryOrSafeFallback("잘 모르겠습니다") == .boundary)

    #expect(parser.scene("EARTH_TERM") == .earthTerm)
    #expect(parser.scene("label=PLAYFUL_COMPASS") == .playfulCompass)
    #expect(parser.scene("EARTH_TERM GENERAL") == nil)
    #expect(parser.scene("UNKNOWN") == nil)
}

@Test
func routedPersonaResponsePromptCombinesPersonaCardAndMemoryContract() throws {
    let prompts = try RoutedPersonaPromptRegistry().load()
    let card = prompts.card(
        boundary: .inScope,
        scene: .returnSignal
    )
    let systemPrompt = prompts.responseSystemPrompt(activeCard: card)

    #expect(systemPrompt.contains("엘레나는 차원 이동"))
    #expect(systemPrompt.contains("확실하진 않아"))
    #expect(systemPrompt.contains("save(P=X,E=Y)"))
    #expect(!systemPrompt.contains("Elena Granular Scene Router"))
}

@Test
func routedPersonaBoundaryCardOverridesSceneCard() throws {
    let prompts = try RoutedPersonaPromptRegistry().load()
    let card = prompts.card(
        boundary: .boundary,
        scene: .playfulCompass
    )

    #expect(card == prompts.boundaryCard)
    #expect(card?.contains("알 수 없는 정보") == true)
}

@Test
func routedPersonaBoundaryResponseDoesNotReceiveRecalledMemory() throws {
    let prompts = try RoutedPersonaPromptRegistry().load()

    #expect(
        prompts.responseUserMessage(
            boundary: .boundary,
            userMessage: "모르는 행성의 역사를 알려줘",
            memoryAugmentedUserMessage: "[과거 기억]\n비밀 정보"
        ) == "모르는 행성의 역사를 알려줘"
    )
    #expect(
        prompts.responseUserMessage(
            boundary: .inScope,
            userMessage: "원문",
            memoryAugmentedUserMessage: "[과거 기억]\n내 취향"
        ) == "[과거 기억]\n내 취향"
    )
}

@Test
func routedPersonaSessionContextKeepsOnlyVisibleConversation() {
    var context = RoutedPersonaSessionContext(maximumTurnCount: 4)
    context.appendExchange(userMessage: "첫 질문", assistantMessage: "첫 답변")
    context.appendExchange(userMessage: "둘째 질문", assistantMessage: "둘째 답변")
    context.appendExchange(userMessage: "셋째 질문", assistantMessage: "셋째 답변")

    let input = context.routerInput(currentUserMessage: "마지막 질문")
    #expect(!input.contains("첫 질문"))
    #expect(!input.contains("첫 답변"))
    #expect(input.contains("둘째 질문"))
    #expect(input.contains("셋째 답변"))
    #expect(input.contains("캐릭터: 셋째 답변"))
    #expect(input.contains("마지막 사용자 요청\n마지막 질문"))
    #expect(!input.contains("BOUNDARY"))
}
