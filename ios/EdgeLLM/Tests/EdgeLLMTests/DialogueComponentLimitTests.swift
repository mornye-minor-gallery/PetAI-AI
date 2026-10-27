import Foundation
import Testing
@testable import EdgeLLM

@Test func hardLoreBudgetIncludesIgnoreBudgetEntriesAndContinuesAfterAnOversizedEntry() async throws {
    let settings = WorldInfoSettings(tokenBudget: 500, entries: [
        .init(id: "oversized", content: String(repeating: "가", count: 100), constant: true, ignoreBudget: true, order: 300),
        .init(id: "reaction", content: "반응 예시", constant: true, ignoreBudget: true, order: 100),
        .init(id: "small", content: "짧은 설정", constant: true, order: 50)
    ])
    let selected = try await WorldInfoEngine.select(settings: settings, messages: [], note: nil,
        measurer: CompactionCounter(), absoluteTokenBudget: 30, preferredEntryIDs: ["reaction"])
    #expect(selected.selected.map(\.id) == ["reaction", "small"])
    #expect(selected.trace.entries.contains { $0.id == "oversized" && $0.reason == .budgetExceeded })
    #expect(selected.trace.tokenBudget == 30)
}

@Test func hardLoreBudgetAcceptsAnExactlyFittingWholeEntry() async throws {
    let settings = WorldInfoSettings(tokenBudget: 100, entries: [
        .init(id: "exact", content: String(repeating: "가", count: 30), constant: true)
    ])
    let selected = try await WorldInfoEngine.select(settings: settings, messages: [], note: nil,
        measurer: CompactionCounter(), absoluteTokenBudget: 30)
    #expect(selected.selected.map(\.id) == ["exact"])
}

@Test func questionLimitsCountSpacesAndUseTheModelTokenizer() async throws {
    let limits = DialoguePromptLimits(fixedTokens: 1024, loreTokens: 512, topicTokens: 512,
        stateTokens: 256, questionTokens: 3, questionCharacters: 5)
    await #expect(throws: DialogueInputLimitError.characters(actual: 6, maximum: 5)) {
        try await limits.validateQuestion("가 나 다 ", measurer: CompactionCounter())
    }
    await #expect(throws: DialogueInputLimitError.tokens(actual: 4, maximum: 3)) {
        try await limits.validateQuestion("abcd", measurer: CompactionCounter())
    }
    try await limits.validateQuestion("abc", measurer: CompactionCounter())
}
