import Foundation
import Testing
@testable import EdgeLLM

struct CompactionCounter: DialogueTokenMeasuring {
    let identifier = "synthetic-character-template"
    func countTokens(_ text: String) async throws -> Int { text.count }
    func measureInput(_ input: DialogueModelInput) async throws -> Int {
        input.messages.reduce(17) { $0 + $1.text.count + 7 }
    }
}

private func compactionBudget(enabled: Bool = true, capacity: Int = 900) -> DialogueTokenBudget {
    .init(memoryTokens: 40, contextTokens: capacity, outputTokens: 100,
          limits: .init(fixedTokens: 150, loreTokens: 80, topicTokens: 80,
                        stateTokens: 80, questionTokens: 50, questionCharacters: 500),
          contextPolicy: .init(summaryEnabled: enabled, summaryTokens: 120, recentTurns: 3))
}

func compactionTemplate() -> DialogueContextTemplate {
    .init(system: [.init(id: "persona", text: "고정 지침", role: .system)],
          context: [.init(id: "profile", text: "현재 상태", role: .system)],
          memory: nil, before: [], after: [], historyBlocks: [])
}

@Test func summaryTailIsCutAtCharacterBoundariesUsingTokenCounts() async throws {
    let text = "안녕하세요👩🏽‍💻.뒤에 덜어낼 내용"
    let trimmed = try await DialogueTokenTruncation.prefix(text, maximumTokens: 6, measurer: CompactionCounter())
    #expect(trimmed == "안녕하세요👩🏽‍💻")
    #expect(text.hasPrefix(trimmed))
    #expect(try await CompactionCounter().countTokens(trimmed) <= 6)
}

@Test func contextCapacityChangesUseTheSamePolicyAtFourAndEightK() async throws {
    let policy = DialogueContextPolicy(summaryEnabled: true, summaryTokens: 500, recentTurns: 3)
    let limits = DialoguePromptLimits(fixedTokens: 1024, loreTokens: 512, topicTokens: 512,
        stateTokens: 256, questionTokens: 300, questionCharacters: 500)
    let entries: [RecentDialogueEntry] = (0..<6).map { index in
        .request(.init(requestID: "r\(index)", userMessage: String(repeating: "질", count: 280),
                       assistantMessage: String(repeating: "답", count: 420), status: .completed))
    }
    let small = DialogueTokenBudget(memoryTokens: 512, contextTokens: 4096, outputTokens: 512, limits: limits, contextPolicy: policy)
    let large = DialogueTokenBudget(memoryTokens: 512, contextTokens: 8192, outputTokens: 512, limits: limits, contextPolicy: policy)
    let needsSmall = try await DialogueContextCompactor.requiresCompaction(template: compactionTemplate(), entries: entries,
        summary: nil, budget: small, measurer: CompactionCounter())
    let needsLarge = try await DialogueContextCompactor.requiresCompaction(template: compactionTemplate(), entries: entries,
        summary: nil, budget: large, measurer: CompactionCounter())
    #expect(needsSmall)
    #expect(!needsLarge)
    let plan = try await DialogueContextCompactor.plan(template: compactionTemplate(), entries: entries,
        previousSummary: nil, budget: small, measurer: CompactionCounter())
    #expect(plan.summaryTokenLimit == 500)
    #expect(plan.retainedEntries.count == 3)
}

@Test func compactedTemplatePreservesSystemUserSystemUserRoles() {
    let template = compactionTemplate()
    let input = template.input(history: [.init(role: .user, text: "질문"), .init(role: .assistant, text: "답")],
                               summary: "옛 맥락", currentMessage: "다음 질문")
    #expect(input.messages.map(\.role) == [.system, .user, .system, .user])
    #expect(input.initialMessages[0].text == "고정 지침")
    #expect(input.initialMessages[1].text.hasPrefix("## 이전 대화 요약\n옛 맥락"))
    #expect(input.initialMessages[1].text.contains("사용자: 질문\n캐릭터: 답"))
}

@Test func compactionRetainsAtMostThreeWholeOriginalTurnsAndSummarizesTheRest() async throws {
    let entries = (0..<10).map { index in
        RecentDialogueEntry.request(.init(requestID: "r\(index)", userMessage: "질문\(index)",
                                          assistantMessage: "답\(index)", status: .completed))
    }
    let plan = try await DialogueContextCompactor.plan(template: compactionTemplate(), entries: entries,
        previousSummary: "이전 요약", budget: compactionBudget(), measurer: CompactionCounter())
    #expect(plan.retainedEntries.map(\.id) == ["r7", "r8", "r9"])
    #expect(plan.summaryInput.contains("이전 요약"))
    #expect(plan.summaryInput.contains("질문6"))
    #expect(!plan.summaryInput.contains("질문7"))
    #expect(plan.excludedEntries.count == 7)
}

@Test func summaryGetsPriorityWhenTheLatestOriginalTurnCannotFit() async throws {
    let entries: [RecentDialogueEntry] = [
        .request(.init(requestID: "short", userMessage: "응", assistantMessage: "응", status: .completed)),
        .request(.init(requestID: "long", userMessage: String(repeating: "긴", count: 600),
                       assistantMessage: "긴 답", status: .completed))
    ]
    let budget = compactionBudget(capacity: 450)
    let plan = try await DialogueContextCompactor.plan(template: compactionTemplate(), entries: entries,
        previousSummary: nil, budget: budget, measurer: CompactionCounter())
    #expect(plan.retainedEntries.isEmpty)
    #expect(plan.summaryTokenLimit == 120)
    #expect(plan.summaryInput.contains(String(repeating: "긴", count: 600)))
    let result = try await DialogueContextCompactor.finish(plan: plan,
        summary: String(repeating: "요", count: 200), template: compactionTemplate(),
        budget: budget, measurer: CompactionCounter())
    #expect(result.summary?.count == 120)
    #expect(result.retainedEntries.isEmpty)
    #expect(result.inputTokens + 50 + 100 <= 450)
}

@Test func summaryDisabledRetainsThreeTurnsWithoutRollingEveryFollowingRequest() async throws {
    let entries = (0..<8).map { index in
        RecentDialogueEntry.request(.init(requestID: "r\(index)", userMessage: "응", assistantMessage: "그래", status: .completed))
    }
    let budget = compactionBudget(enabled: false)
    let plan = try await DialogueContextCompactor.plan(template: compactionTemplate(), entries: entries,
        previousSummary: "지울 요약", budget: budget, measurer: CompactionCounter())
    #expect(plan.summaryTokenLimit == 0)
    #expect(plan.retainedEntries.map(\.id) == ["r5", "r6", "r7"])
    let result = try await DialogueContextCompactor.finish(plan: plan, summary: nil,
        template: compactionTemplate(), budget: budget, measurer: CompactionCounter())
    #expect(result.summary == nil)
    #expect(result.inputTokens + 50 + 100 <= 900)
}
