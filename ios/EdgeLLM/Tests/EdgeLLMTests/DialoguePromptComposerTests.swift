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
        #expect(result.trace.userSections.contains("scene"))
        #expect(result.trace.systemSections.contains("nameRule") == (placement == .system))
        let expected = placement == .system ? ["scene", "profile", "memories", "currentMessage"] :
            placement == .beforeCurrent ? ["scene", "profile", "memories", "nameRule", "currentMessage"] : ["scene", "profile", "memories", "currentMessage", "nameRule"]
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

@Test func composerRetainsHistoryPrefixWhenRequestContextChanges() throws {
    let prompts = try testPersona()
    let history: [RoutedPersonaSessionContext.Turn] = [
        .init(role: .user, text: "앞선 질문"), .init(role: .assistant, text: "앞선 답변")
    ]
    let historyPrefix = "## 최근 대화\n" + history.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
    let first = try DialoguePromptComposer.prepare(input: .init(
        persona: prompts, activeCard: "첫 장면", profile: .init(userName: "테스터", dailySteps: [
            .init(date: "2026-10-02", steps: 100)
        ]), history: history, memories: [promptMemory("첫 기억", index: 0)], currentMessage: "첫 질문",
        exampleDialogue: "고정 대화 예시"))
    let second = try DialoguePromptComposer.prepare(input: .init(
        persona: prompts, activeCard: "둘째 장면", profile: .init(userName: "테스터", dailySteps: [
            .init(date: "2026-10-02", steps: 200)
        ]), history: history, memories: [promptMemory("둘째 기억", index: 0)], currentMessage: "둘째 질문",
        exampleDialogue: "고정 대화 예시"))

    #expect(first.systemPrompt == second.systemPrompt)
    #expect(first.trace.systemSections == ["persona", "responseContract", "nameRule", "dialogue.examples"])
    for prepared in [first, second] {
        #expect(prepared.userPrompt.hasPrefix(historyPrefix))
        #expect(prepared.trace.userSections == ["history", "scene", "profile", "memories", "currentMessage"])
        #expect(prepared.tokenSections.filter { $0.role == .system }.map(\.id) == prepared.trace.systemSections)
        #expect(prepared.tokenSections.filter { $0.role == .user }.map(\.id) == prepared.trace.userSections)
    }
    #expect(first.userPrompt.contains("첫 장면"))
    #expect(first.userPrompt.contains("100걸음"))
    #expect(first.userPrompt.contains("첫 기억"))
    #expect(first.userPrompt.hasSuffix("첫 질문"))
    #expect(second.userPrompt.contains("둘째 장면"))
    #expect(second.userPrompt.contains("200걸음"))
    #expect(second.userPrompt.contains("둘째 기억"))
    #expect(second.userPrompt.hasSuffix("둘째 질문"))
}

@Test func composerKeepsMainPromptAnchorOrderAfterHistory() throws {
    let history: [RoutedPersonaSessionContext.Turn] = [.init(role: .user, text: "앞선 질문")]
    let prepared = try DialoguePromptComposer.prepare(input: .init(
        persona: try testPersona(), activeCard: "선택한 장면 설정", history: history, currentMessage: "현재 질문",
        insertions: [
            .init(id: "context.begin", source: .worldInfo, text: "문맥 시작", placement: .beforeSystem),
            .init(id: "scene.before", source: .worldInfo, text: "장면 앞", placement: .beforePersona),
            .init(id: "scene.after", source: .worldInfo, text: "장면 뒤", placement: .afterPersona),
            .init(id: "context.end", source: .worldInfo, text: "문맥 끝", placement: .afterSystem)
        ]))

    #expect(prepared.trace.systemSections == ["persona", "responseContract", "nameRule"])
    #expect(prepared.trace.userSections == ["history", "context.begin", "scene.before", "scene", "scene.after", "profile", "context.end", "currentMessage"])
    var remaining = prepared.userPrompt[...]
    for text in ["앞선 질문", "문맥 시작", "장면 앞", "선택한 장면 설정", "장면 뒤", "현재 세션 사용자 컨텍스트", "문맥 끝", "현재 질문"] {
        let range = try #require(remaining.range(of: text), "Missing or reordered context: \(text)")
        remaining = remaining[range.upperBound...]
        #expect(prepared.userPrompt.components(separatedBy: text).count == 2, "\(text)")
    }
    #expect(prepared.trace.insertions.allSatisfy { $0.requestedRole == .system && $0.deliveredRole == .user })
}
