import Foundation
import Testing
@testable import EdgeLLM

@Test func compactedSummaryAndOriginalSuffixAreSavedTogether() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compaction-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DialogueSessionFileStore(fileURL: directory.appendingPathComponent("recent.json"))
    var session = RoutedPersonaSessionContext()
    for index in 0..<8 { _ = session.appendExchange(userMessage: "질문 \(index)", assistantMessage: "답") }
    let kept = Array(session.contextEntries.suffix(3))
    try store.compact(in: &session, retaining: kept, summary: "앞부분을 정리했어요", modelIdentifier: "test-model")
    let loaded = try store.load()
    let restored = try #require(loaded)
    #expect(restored.summary == "앞부분을 정리했어요")
    #expect(restored.summaryModelIdentifier == "test-model")
    #expect(restored.contextEntries == kept)
    #expect(restored.completedUserMessages == 8)
    #expect(restored.checkpoint().summary == "앞부분을 정리했어요")
}

@Test func compactionWriteFailurePreservesTheAuthoritativeSession() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compaction-failure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let blocker = directory.appendingPathComponent("blocker")
    try Data("file".utf8).write(to: blocker)
    let store = DialogueSessionFileStore(fileURL: blocker.appendingPathComponent("recent.json"))
    var session = RoutedPersonaSessionContext()
    _ = session.appendExchange(userMessage: "하나", assistantMessage: "답")
    _ = session.appendExchange(userMessage: "둘", assistantMessage: "답")
    let before = session
    #expect(throws: (any Error).self) {
        try store.compact(in: &session, retaining: Array(session.contextEntries.suffix(1)),
                          summary: "요약", modelIdentifier: "test-model")
    }
    #expect(session == before)
}

@Test func compactionPreservesAnAlreadyAdmittedUserRequest() throws {
    var session = RoutedPersonaSessionContext()
    _ = session.appendExchange(userMessage: "이전", assistantMessage: "답")
    _ = try session.beginRequest(requestID: "active", userMessage: "현재")
    try session.compact(retaining: [], summary: "이전 요약", modelIdentifier: "test-model")
    #expect(session.chatTurns.last?.requestID == "active")
    #expect(session.chatTurns.last?.status == .inProgress)
    #expect(session.turns.isEmpty)
    #expect(session.summary == "이전 요약")
    _ = try session.finishRequest(requestID: "active", status: .cancelled)
    #expect(session.contextEntries.last?.id == "active")
}

@Test func compactionOnlyAcceptsAnUnchangedContiguousSuffix() throws {
    var session = RoutedPersonaSessionContext()
    _ = session.appendExchange(userMessage: "하나", assistantMessage: "답")
    _ = session.appendExchange(userMessage: "둘", assistantMessage: "답")
    let invalid = [session.contextEntries[0]]
    #expect(throws: DialogueSessionError.staleSnapshot) {
        try session.compact(retaining: invalid, summary: "요약", modelIdentifier: "test-model")
    }
    #expect(session.contextEntries.count == 2)
}
