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
    #expect(result.systemText == "검사자는 검사 전용 캐릭터다.")
    #expect(result.userText.contains("질문 하나"))
    #expect(result.userText.contains("답변 하나"))
    #expect(result.userText.hasSuffix("질문 둘"))
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
    #expect(result.userText.contains("- 차"))
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
        #expect(result.trace.userBytes == result.userText.utf8.count)
        #expect(result.responseConfiguration.memoryClassification)
    }
}

@Test func composerRejectsInvalidByteBudget() throws {
    let input = DialoguePromptInput(persona: try testPersona(), currentMessage: "질문")
    #expect(throws: DialoguePromptError.invalidMemoryByteBudget) {
        try DialoguePromptComposer.prepare(input: input, policy: .init(memoryByteBudget: 0))
    }
}

@Test func composerPreservesRolesWhenContextFollowsHistory() throws {
    let prepared = try DialoguePromptComposer.prepare(input: .init(
        persona: try testPersona(), activeCard: "선택한 장면", history: [
            .init(role: .user, text: "앞선 질문"), .init(role: .assistant, text: "앞선 답변")
        ], currentMessage: "현재 질문", insertions: [
            .init(id: "lore", source: .worldInfo, text: "이번 요청의 로어", placement: .afterPersona),
            .init(id: "reaction", source: .worldInfo, text: "기존 응답 참고", placement: .inChat, depth: 0)
        ]))
    #expect(prepared.trace.systemSections.contains("scene"))
    #expect(prepared.trace.systemSections.contains("profile"))
    #expect(prepared.trace.insertions.first { $0.id == "lore" }?.deliveredRole == .system)
    #expect(prepared.trace.insertions.first { $0.id == "reaction" }?.deliveredRole == .user)
    #expect(prepared.tokenSections.map(\.id) == ["persona", "responseContract", "nameRule",
        "history", "scene", "lore", "profile", "currentMessage", "reaction"])
    #expect(prepared.tokenSections.map(\.role) == [.system, .system, .system,
        .user, .system, .system, .system, .user, .user])
    #expect(prepared.modelInput.messages.map(\.role) == [.system, .user, .system, .user])
    #expect(prepared.modelInput.initialMessages[1].text.contains("앞선 답변"))
    #expect(prepared.modelInput.initialMessages[2].text.contains("이번 요청의 로어"))
    #expect(prepared.modelInput.currentUserMessage == "## 현재 사용자 입력과 회수 기억\n현재 질문\n\n기존 응답 참고")
    #expect(try JSONDecoder().decode(DialogueModelInput.self,
        from: JSONEncoder().encode(prepared.modelInput)) == prepared.modelInput)
}

@Test func modelInputRejectsMissingOrNonUserFinalMessage() throws {
    for json in ["{\"messages\":[]}", "{\"messages\":[{\"role\":\"system\",\"text\":\"context\"}]}"] {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DialogueModelInput.self, from: Data(json.utf8))
        }
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

    #expect(first.modelInput.initialMessages.prefix(2) == second.modelInput.initialMessages.prefix(2))
    #expect(first.modelInput.initialMessages[2] != second.modelInput.initialMessages[2])
    #expect(first.trace.systemSections == ["persona", "responseContract", "nameRule", "dialogue.examples", "scene", "profile"])
    for prepared in [first, second] {
        #expect(prepared.userText.hasPrefix(historyPrefix))
        #expect(prepared.modelInput.messages.map(\.role) == [.system, .user, .system, .user])
        #expect(prepared.trace.userSections == ["history", "memories", "currentMessage"])
        #expect(prepared.tokenSections.filter { $0.role == .system }.map(\.id) == prepared.trace.systemSections)
        #expect(prepared.tokenSections.filter { $0.role == .user }.map(\.id) == prepared.trace.userSections)
    }
    #expect(first.systemText.contains("첫 장면"))
    #expect(first.systemText.contains("100걸음"))
    #expect(first.userText.contains("첫 기억"))
    #expect(first.userText.hasSuffix("첫 질문"))
    #expect(second.systemText.contains("둘째 장면"))
    #expect(second.systemText.contains("200걸음"))
    #expect(second.userText.contains("둘째 기억"))
    #expect(second.userText.hasSuffix("둘째 질문"))
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

    #expect(prepared.trace.systemSections == ["persona", "responseContract", "nameRule", "context.begin", "scene.before", "scene", "scene.after", "profile", "context.end"])
    #expect(prepared.trace.userSections == ["history", "currentMessage"])
    let fullText = prepared.modelInput.messages.map(\.text).joined(separator: "\n\n")
    var remaining = fullText[...]
    for text in ["앞선 질문", "문맥 시작", "장면 앞", "선택한 장면 설정", "장면 뒤", "현재 세션 사용자 컨텍스트", "문맥 끝", "현재 질문"] {
        let range = try #require(remaining.range(of: text), "Missing or reordered context: \(text)")
        remaining = remaining[range.upperBound...]
        #expect(fullText.components(separatedBy: text).count == 2, "\(text)")
    }
    #expect(prepared.trace.insertions.allSatisfy { $0.requestedRole == .system && $0.deliveredRole == .system })
}
