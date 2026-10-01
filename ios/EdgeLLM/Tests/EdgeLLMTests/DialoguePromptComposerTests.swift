#if os(Android)
import Crypto
#else
import CryptoKit
#endif
import Foundation
import Testing
@testable import EdgeLLM

private func promptMemory(_ text: String, index: Int) -> RetrievedMemoryObservation {
    let date = Date(timeIntervalSince1970: 0)
    return RetrievedMemoryObservation(observation: MemoryObservation(
        id: "fixture-\(index)", turnID: "fixture-\(index)", sessionID: "fixture",
        sequence: index, scope: MemoryScope(userID: "synthetic", characterID: "synthetic"),
        occurredAt: date, rawText: text, labelEvidence: [], createdAt: date), score: 1, rank: index)
}

@Test func composerPreservesExplicitCoreAndHistory() throws {
    let prompts = try testPersona()
    var session = RoutedPersonaSessionContext()
    session.appendExchange(userMessage: "질문 하나", assistantMessage: "답변 하나")
    let config = PersonaResponseConfiguration(includePersona: true, includeSessionContext: false,
        enforceCharacterName: false, memoryClassification: false)
    let result = try DialoguePromptComposer.prepare(input: .init(persona: prompts,
        profile: .init(characterName: "검사자"), history: session.turns, currentMessage: "질문 둘"),
        policy: .init(persona: config))
    #expect(result.systemPrompt == "검사자는 검사 전용 캐릭터다.")
    #expect(result.userPrompt.contains("질문 하나"))
    #expect(result.userPrompt.contains("답변 하나"))
    #expect(result.userPrompt.hasSuffix("질문 둘"))
}

@Test func composerRejectsInactiveNamePlacement() throws {
    let input = DialoguePromptInput(persona: try testPersona(), currentMessage: "안녕")
    #expect(throws: DialoguePromptError.self) {
        try DialoguePromptComposer.prepare(input: input, policy: .init(
            persona: .init(enforceCharacterName: false), nameRulePlacement: .beforeCurrent))
    }
}

@Test func composerReportsExcludedMemoryWithoutChangingSources() throws {
    let memories = [promptMemory("너무 긴 기억", index: 0), promptMemory("차", index: 1), promptMemory("  ", index: 2)]
    let input = DialoguePromptInput(persona: try testPersona(), memories: memories, currentMessage: "질문")
    let result = try DialoguePromptComposer.prepare(input: input, policy: .init(memoryByteBudget: 5))
    #expect(result.trace.memories.map(\.reason) == [.budgetExceeded, .included, .empty])
    #expect(result.trace.insertedMemoryCount == 1)
    #expect(result.trace.insertedMemoryBytes == 5)
    #expect(input.memories.count == 3)
    #expect(result.userPrompt.contains("- 차"))
}

@Test func composerTraceMatchesPlacementAndRetainsOutputContract() throws {
    let input = DialoguePromptInput(persona: try testPersona(),
        activeCard: "장면 규칙", memories: [promptMemory("기억", index: 0)], currentMessage: "아영아?")
    for placement in NameRulePlacement.allCases {
        let result = try DialoguePromptComposer.prepare(input: input, policy: .init(nameRulePlacement: placement))
        #expect(result.trace.systemSections.contains("responseContract"))
        #expect(result.trace.systemSections.contains("scene"))
        #expect(result.trace.systemSections.contains("nameRule") == (placement == .system))
        let expected = placement == .system ? ["memories", "currentMessage"] :
            placement == .beforeCurrent ? ["memories", "nameRule", "currentMessage"] : ["memories", "currentMessage", "nameRule"]
        #expect(result.trace.userSections == expected)
        #expect(result.trace.userBytes == result.userPrompt.utf8.count)
        #expect(result.responseConfiguration.memoryClassification)
    }
}

@Test func composerRejectsInvalidByteBudget() throws {
    let input = DialoguePromptInput(persona: try testPersona(), currentMessage: "질문")
    #expect(throws: DialoguePromptError.invalidMemoryByteBudget) {
        try DialoguePromptComposer.prepare(input: input, policy: .init(memoryByteBudget: 0))
    }
}
