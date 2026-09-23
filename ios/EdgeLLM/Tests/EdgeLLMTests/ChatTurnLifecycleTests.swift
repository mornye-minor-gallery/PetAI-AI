import Foundation
import Testing
@testable import EdgeLLM

@Test func cancelledUserMessageAdvancesVisibleClockWithoutCompletingExchange() throws {
    var session = RoutedPersonaSessionContext()
    let first = try session.beginRequest(requestID: "first", userMessage: "엘레나야?")
    #expect(first.history.isEmpty)
    #expect(try session.finishRequest(requestID: "first", status: .cancelled) == .committed)
    #expect(session.chatTurns.map(\.status) == [.cancelled])
    #expect(session.visibleUserMessages == 1)
    #expect(session.visibleMessages == 1)
    #expect(session.completedUserMessages == 0)
    #expect(session.completedMessages == 0)
    let next = try session.beginRequest(requestID: "second", userMessage: "같이 놀자")
    #expect(next.currentUserMessageNumber == 2)
    #expect(next.currentMessageNumber == 2)
    #expect(next.history.count == 1)
    #expect(next.history[0].text.contains("엘레나야?"))
    #expect(next.history[0].text.contains("취소"))
}

@Test func partialCancelledAnswerIsOneVisibleMessageAndNeverCompleted() throws {
    var session = RoutedPersonaSessionContext()
    _ = try session.beginRequest(requestID: "first", userMessage: "게임하자")
    try session.appendAssistantText(requestID: "first", text: "응, ")
    try session.appendAssistantText(requestID: "first", text: "좋아")
    #expect(try session.finishRequest(requestID: "first", status: .cancelled) == .committed)
    #expect(try session.finishRequest(requestID: "first", status: .cancelled) == .alreadyCommitted)
    #expect(session.visibleMessages == 2)
    #expect(session.completedMessages == 0)
    let next = try session.snapshot(requestID: "next")
    #expect(next.history.count == 2)
    #expect(next.history[1].text.contains("응, 좋아"))
    #expect(next.history[1].text.contains("중단"))
    #expect(next.currentUserMessageNumber == 2)
    #expect(next.currentMessageNumber == 3)
}

@Test func failedRequestKeepsUserAndPartialButNotWorldInfoOrCompletedClock() throws {
    var session = RoutedPersonaSessionContext()
    _ = try session.beginRequest(requestID: "first", userMessage: "게임하자")
    try session.appendAssistantText(requestID: "first", text: "잠깐")
    #expect(throws: DialogueSessionError.invalidExchange) {
        try session.finishRequest(requestID: "first", status: .failed,
            worldInfo: .init(state: .init(), text: .init()))
    }
    #expect(try session.finishRequest(requestID: "first", status: .failed) == .committed)
    #expect(session.chatTurns[0].status == .failed)
    #expect(session.completedMessages == 0)
    #expect(session.visibleMessages == 2)
    #expect(throws: DialogueSessionError.conflictingCommit) {
        try session.finishRequest(requestID: "first", status: .completed)
    }
}

@Test func retentionCountsRequestsAndCheckpointPreservesInterruptedTurns() throws {
    var session = RoutedPersonaSessionContext(maximumTurnCount: 20)
    for index in 0..<22 {
        _ = try session.beginRequest(requestID: "id-\(index)", userMessage: "질문 \(index)")
        if index.isMultiple(of: 2) {
            try session.appendAssistantText(requestID: "id-\(index)", text: "답변 \(index)")
            try session.finishRequest(requestID: "id-\(index)", status: .completed)
        } else {
            try session.finishRequest(requestID: "id-\(index)", status: .cancelled)
        }
    }
    #expect(session.chatTurns.count == 20)
    #expect(session.chatTurns.first?.userMessage == "질문 2")
    #expect(session.visibleUserMessages == 22)
    #expect(session.visibleMessages == 33)
    #expect(session.completedUserMessages == 11)
    let restored = try RoutedPersonaSessionContext(checkpoint: session.checkpoint())
    #expect(restored.chatTurns == session.chatTurns)
    #expect(restored.visibleUserMessages == 22)
    #expect(restored.visibleMessages == 33)
}

@Test func staleRequestCannotAppendOrFinishNewRequest() throws {
    var session = RoutedPersonaSessionContext()
    _ = try session.beginRequest(requestID: "old", userMessage: "첫 질문")
    try session.finishRequest(requestID: "old", status: .cancelled)
    _ = try session.beginRequest(requestID: "new", userMessage: "새 질문")
    #expect(throws: DialogueSessionError.staleSnapshot) {
        try session.appendAssistantText(requestID: "old", text: "늦은 답변")
    }
    #expect(throws: DialogueSessionError.staleSnapshot) {
        try session.finishRequest(requestID: "old", status: .failed)
    }
    #expect(session.chatTurns.last?.assistantMessage == "")
    try session.finishRequest(requestID: "new", status: .cancelled)
    #expect(throws: DialogueSessionError.conflictingCommit) {
        try session.beginRequest(requestID: "new", userMessage: "중복 요청")
    }
}

@Test func cancelledUserMessageAdvancesAuthorsNoteSchedule() throws {
    var session = RoutedPersonaSessionContext()
    _ = try session.beginRequest(requestID: "first", userMessage: "엘레나야?")
    try session.finishRequest(requestID: "first", status: .cancelled)
    let next = try session.beginRequest(requestID: "second", userMessage: "게임하자")
    let input = DialoguePromptInput(persona: try testPersona(), history: next.history,
        currentMessage: "게임하자", session: next,
        authorsNote: .init(defaults: .init(text: "두 번째 발화 노트", interval: 2)))
    let prepared = try DialoguePromptComposer.prepare(input: input)
    #expect(prepared.trace.authorsNote?.userMessageNumber == 2)
    #expect(prepared.trace.authorsNote?.active == true)
    #expect(prepared.userPrompt.contains("두 번째 발화 노트"))
}

@Test func checkpointConvertsPendingOwnershipIntoInterruptedTurn() throws {
    var session = RoutedPersonaSessionContext()
    _ = try session.beginRequest(requestID: "pending", userMessage: "게임하자")
    try session.appendAssistantText(requestID: "pending", text: "좋아")
    let restored = try RoutedPersonaSessionContext(checkpoint: session.checkpoint())
    #expect(restored.chatTurns[0].status == .cancelled)
    #expect(restored.visibleMessages == 2)
    #expect(restored.completedMessages == 0)
    #expect(try restored.snapshot(requestID: "next").history[1].text.contains("중단"))
}
