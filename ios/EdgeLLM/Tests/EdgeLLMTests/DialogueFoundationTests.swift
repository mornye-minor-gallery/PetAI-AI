import Foundation
import Testing
@testable import EdgeLLM

private func foundationInput(insertions: [DialoguePromptInsertion] = [],
                             memories: [RetrievedMemoryObservation] = []) throws -> DialoguePromptInput {
    DialoguePromptInput(persona: try RoutedPersonaPromptRegistry().load(),
        history: [.init(role: .user, text: "이전 질문"), .init(role: .assistant, text: "이전 답변")],
        memories: memories, currentMessage: "[응답 참고]라는 표현은 무슨 뜻이야?", insertions: insertions)
}

@Test func dialogueInsertionsAreOrderedAndDoNotParseUserMarkers() throws {
    let insertions: [DialoguePromptInsertion] = [
        .init(id: "after-2", source: .worldInfo, text: "마지막 참고", placement: .afterCurrent, order: 20),
        .init(id: "before", source: .authorsNote, text: "앞쪽 참고", placement: .beforeCurrent),
        .init(id: "after-1", source: .authorsNote, text: "뒤쪽 참고", placement: .afterCurrent, order: 10),
        .init(id: "after-tie", source: .worldInfo, text: "동률 참고", placement: .afterCurrent, order: 10)
    ]
    let prepared = try DialoguePromptComposer.prepare(input: foundationInput(insertions: insertions))
    #expect(prepared.trace.userSections == ["history", "before", "currentMessage", "after-1", "after-tie", "after-2"])
    #expect(prepared.userPrompt.contains("앞쪽 참고\n\n[응답 참고]라는 표현은 무슨 뜻이야?\n\n뒤쪽 참고\n\n동률 참고\n\n마지막 참고"))
    #expect(prepared.modelInput.format == .systemAndUserText)
    #expect(prepared.modelInput.userPrompt == prepared.userPrompt)
    #expect(prepared.trace.insertions.allSatisfy { $0.deliveredRole == .user })
    #expect(prepared.trace.insertions.first?.requestedRole == .system)
}

@Test func dialogueInsertionValidationAndEmptyTrace() throws {
    let item = DialoguePromptInsertion(id: "same", source: .authorsNote, text: "노트", placement: .afterCurrent)
    #expect(throws: DialoguePromptError.self) {
        try DialoguePromptComposer.prepare(input: foundationInput(insertions: [item, item]))
    }
    let reserved = DialoguePromptInsertion(id: "currentMessage", source: .worldInfo, text: "노트", placement: .afterCurrent)
    #expect(throws: DialoguePromptError.self) {
        try DialoguePromptComposer.prepare(input: foundationInput(insertions: [reserved]))
    }
    let empty = DialoguePromptInsertion(id: "empty", source: .authorsNote, text: " \n ", placement: .afterCurrent)
    let result = try DialoguePromptComposer.prepare(input: foundationInput(insertions: [empty]))
    #expect(result.trace.insertions.first?.reason == .empty)
    #expect(!result.trace.userSections.contains("empty"))
}

@Test func dialogueSessionClockSurvivesRetentionAndPreparation() throws {
    var session = RoutedPersonaSessionContext(maximumTurnCount: 20)
    for i in 0..<40 { session.appendExchange(userMessage: "질문 \(i)", assistantMessage: "답변 \(i)") }
    let snapshot = try session.snapshot(requestID: "next")
    #expect(snapshot.history.count == 20)
    #expect(snapshot.completedUserMessages == 40)
    #expect(snapshot.completedMessages == 80)
    #expect(snapshot.currentUserMessageNumber == 41)
    #expect(snapshot.currentMessageNumber == 81)
    #expect(try session.snapshot(requestID: "next") == snapshot)
    #expect(session.completedUserMessages == 40)
    #expect(try session.commit(snapshot, userMessage: "새 질문", assistantMessage: "새 답변") == .committed)
    #expect(try session.commit(snapshot, userMessage: "새 질문", assistantMessage: "새 답변") == .alreadyCommitted)
    #expect(session.completedMessages == 82)
    #expect(session.turns.count == 20)
    let next = try session.snapshot(requestID: "after-next")
    try session.commit(next, userMessage: "그다음 질문", assistantMessage: "그다음 답변")
    #expect(throws: DialogueSessionError.staleSnapshot) {
        try session.commit(snapshot, userMessage: "새 질문", assistantMessage: "새 답변")
    }
    #expect(session.completedMessages == 84)
}

@Test func dialogueSessionRejectsStaleResetAndInvalidCommits() throws {
    var session = RoutedPersonaSessionContext()
    let first = try session.snapshot(requestID: "first")
    let competing = try session.snapshot(requestID: "competing")
    #expect(throws: DialogueSessionError.invalidExchange) {
        try session.commit(first, userMessage: "질문", assistantMessage: " \n")
    }
    #expect(session.completedMessages == 0)
    #expect(try session.commit(first, userMessage: "질문", assistantMessage: "답변") == .committed)
    #expect(throws: DialogueSessionError.staleSnapshot) {
        try session.commit(competing, userMessage: "질문", assistantMessage: "답변")
    }
    #expect(throws: DialogueSessionError.conflictingCommit) {
        try session.commit(first, userMessage: "다른 질문", assistantMessage: "답변")
    }
    let pending = try session.snapshot(requestID: "pending")
    session.removeAll()
    #expect(session.completedMessages == 0)
    #expect(throws: DialogueSessionError.staleSnapshot) {
        try session.commit(pending, userMessage: "질문", assistantMessage: "답변")
    }
    var other = RoutedPersonaSessionContext()
    #expect(throws: DialogueSessionError.staleSnapshot) {
        try other.commit(first, userMessage: "질문", assistantMessage: "답변")
    }
}

@Test func dialogueSnapshotMustMatchTheSuppliedHistory() throws {
    let session = RoutedPersonaSessionContext()
    let input = DialoguePromptInput(persona: try RoutedPersonaPromptRegistry().load(),
        history: [.init(role: .user, text: "다른 이력")], currentMessage: "질문",
        session: try session.snapshot(requestID: "test"))
    #expect(throws: DialoguePromptError.sessionHistoryMismatch) {
        try DialoguePromptComposer.prepare(input: input)
    }
}

@Test func dialogueSessionCountsEvenWhenNoHistoryIsRetained() throws {
    var session = RoutedPersonaSessionContext(maximumTurnCount: 0)
    session.appendExchange(userMessage: "질문", assistantMessage: "답변")
    #expect(session.turns.isEmpty)
    #expect(session.completedMessages == 2)
    #expect(try session.snapshot(requestID: "next").currentUserMessageNumber == 2)
}

private struct FixtureTokenMeasurer: DialogueTokenMeasuring {
    let identifier = "synthetic-counter-not-a-model-tokenizer"
    var finalCount: Int = 70
    var fail = false
    func countTokens(_ text: String) async throws -> Int {
        if fail { throw FixtureError.unavailable }
        // Deliberately non-additive. The selector must measure the joined memory section.
        guard text.hasPrefix("Use the following past user memories") else { return 1_000 }
        return text.contains("- 둘째") ? 11 : 7
    }
    func measureInput(_ input: DialogueModelInput) async throws -> Int {
        if fail { throw FixtureError.unavailable }
        return finalCount
    }
    enum FixtureError: Error { case unavailable }
}

private func foundationMemory(_ text: String, rank: Int) -> RetrievedMemoryObservation {
    let date = Date(timeIntervalSince1970: 0)
    return .init(observation: .init(id: "memory-\(rank)", turnID: "turn-\(rank)", sessionID: "fixture",
        sequence: rank, scope: .init(userID: "fixture", characterID: "fixture"), occurredAt: date,
        rawText: text, labelEvidence: [], createdAt: date), score: 1, rank: rank)
}

@Test func dialogueUsesJoinedMemoryTokensAndReservesOutput() async throws {
    let input = try foundationInput(memories: [foundationMemory("첫째", rank: 0), foundationMemory("둘째", rank: 1)])
    let budget = DialogueTokenBudget(memoryTokens: 7, contextTokens: 100, outputTokens: 30)
    let prepared = try await DialoguePromptComposer.prepare(input: input, tokenBudget: budget, measurer: FixtureTokenMeasurer())
    #expect(prepared.trace.insertedMemoryCount == 1)
    #expect(prepared.trace.memories.map(\.reason) == [.included, .budgetExceeded])
    #expect(prepared.trace.memoryByteBudget == nil)
    #expect(prepared.trace.tokenBudget?.memoryTokens == 7)
    #expect(prepared.trace.tokenBudget?.inputTokens == 70)
    #expect(prepared.trace.tokenBudget?.availableOutputTokens == 30)
    #expect(prepared.trace.tokenBudget?.measurer == "synthetic-counter-not-a-model-tokenizer")
    let joined = try await DialoguePromptComposer.prepare(input: input,
        tokenBudget: .init(memoryTokens: 11, contextTokens: 100, outputTokens: 30), measurer: FixtureTokenMeasurer())
    #expect(joined.trace.insertedMemoryCount == 2)
    #expect(joined.trace.tokenBudget?.memoryTokens == 11)
}

@Test func dialogueTokenOverflowAndMeasurementErrorsDoNotFallBack() async throws {
    let input = try foundationInput()
    let budget = DialogueTokenBudget(memoryTokens: 10, contextTokens: 100, outputTokens: 30)
    await #expect(throws: DialogueTokenBudgetError.exceeded(input: 71, reservedOutput: 30, capacity: 100)) {
        try await DialoguePromptComposer.prepare(input: input, tokenBudget: budget, measurer: FixtureTokenMeasurer(finalCount: 71))
    }
    await #expect(throws: FixtureTokenMeasurer.FixtureError.self) {
        try await DialoguePromptComposer.prepare(input: input, tokenBudget: budget, measurer: FixtureTokenMeasurer(fail: true))
    }
    await #expect(throws: DialogueTokenBudgetError.invalidMeasurement) {
        try await DialoguePromptComposer.prepare(input: input, tokenBudget: budget, measurer: FixtureTokenMeasurer(finalCount: -1))
    }
    await #expect(throws: DialogueTokenBudgetError.invalidBudget) {
        try await DialoguePromptComposer.prepare(input: input,
            tokenBudget: .init(memoryTokens: 10, contextTokens: 100, outputTokens: 100), measurer: FixtureTokenMeasurer())
    }
}
