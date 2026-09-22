import Foundation
import Testing
@testable import EdgeLLM

@Test func dialogueProductionBudgetSeparatesMemoryAndOutput() throws {
    let budget = SLMConfiguration.production.dialogueBudget
    #expect(budget.contextTokens == 4_096)
    #expect(budget.memoryTokens == 2_048)
    #expect(budget.outputTokens == 1_024)
    try budget.validate()
    // Existing byte fixtures and tool generations are separate consumers.
    #expect(SLMConfiguration.production.memory.promptByteBudget == 10_000)
    #expect(SLMConfiguration.production.generation.maxOutputTokens == budget.outputTokens)
}

private struct SectionCounter: DialogueTokenMeasuring {
    let identifier = "synthetic-section-counter"
    func countTokens(_ text: String) async throws -> Int { text.utf8.count }
    func measureInput(_ input: DialogueModelInput) async throws -> Int { 600 }
}

@Test func dialogueSectionCountsAreSeparateFromTemplateMeasurement() async throws {
    let prompts = try testPersona()
    let input = DialoguePromptInput(persona: prompts,
        history: [.init(role: .user, text: "이전 질문"), .init(role: .assistant, text: "이전 답변")],
        currentMessage: "현재 질문",
        insertions: [.init(id: "reminder", source: .authorsNote, text: "짧게 대답해", placement: .afterCurrent)])
    let prepared = try await DialoguePromptComposer.prepare(input: input,
        tokenBudget: .init(memoryTokens: 100, contextTokens: 800, outputTokens: 200), measurer: SectionCounter())
    let trace = try #require(prepared.trace.tokenBudget)
    #expect(trace.inputTokens == 600)
    #expect(trace.sections.contains { $0.id == "currentMessage" && $0.tokens == "현재 질문".utf8.count })
    #expect(trace.sections.contains { $0.id == "reminder" && $0.tokens == "짧게 대답해".utf8.count })
    #expect(trace.sections.contains { $0.id == "history" })
    #expect(trace.sections.reduce(0) { $0 + $1.tokens } != trace.inputTokens)
}
