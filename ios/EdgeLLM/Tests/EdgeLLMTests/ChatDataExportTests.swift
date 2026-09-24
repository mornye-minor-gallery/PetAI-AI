import Foundation
import Testing
@testable import EdgeLLM

@Test
func chatDataExportKeepsOnlyRetainedTurnsAndActiveMemories() throws {
    var session = RoutedPersonaSessionContext(maximumTurnCount: 2)
    for index in 1...3 {
        let id = "turn-\(index)"
        _ = try session.beginRequest(requestID: id, userMessage: "질문 \(index)")
        try session.finishRequest(requestID: id, status: .completed, assistantMessage: "답변 \(index)")
    }
    _ = try session.beginRequest(requestID: "turn-4", userMessage: "게임하자")
    try session.appendAssistantText(requestID: "turn-4", text: "좋아")
    try session.finishRequest(requestID: "turn-4", status: .cancelled)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let memory = MemoryObservation(id: "memory-1", turnID: "turn-3", sessionID: "session",
        sequence: 0, scope: .init(userID: "local-user", characterID: "elena"),
        occurredAt: now, rawText: "질문 3",
        labelEvidence: [.init(label: .preference, score: nil, source: .gemmaHeader,
            classifierVersion: "test")], createdAt: now)
    let exported = try ChatDataExport(recentEntries: session.recentEntries, activeMemories: [memory], exportedAt: now)
    let json = try JSONSerialization.jsonObject(with: exported.jsonData()) as! [String: Any]
    let turns = json["recentEntries"] as! [[String: Any]]
    let memories = json["longTermMemories"] as! [[String: Any]]

    #expect(json["formatVersion"] as? Int == 2)
    #expect(turns.map { $0["id"] as! String } == ["turn-3", "turn-4"])
    #expect(turns[1]["assistantMessage"] as? String == "좋아")
    #expect(turns[1]["status"] as? String == "cancelled")
    #expect(turns[0]["characterID"] == nil)
    #expect(memories.count == 1)
    #expect(memories[0]["sourceTurnID"] as? String == "turn-3")
    #expect(memories[0]["characterID"] as? String == "elena")
    #expect(memories[0]["labels"] as? [String] == ["preference"])
    #expect(memories[0]["embedding"] == nil)
}

@Test
func chatDataExportSupportsLongTermOnlyAndEmptyAfterDeletion() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let memory = MemoryObservation(id: "memory-1", turnID: "old-turn", sessionID: "session",
        sequence: 0, scope: .init(userID: "local-user", characterID: "other"),
        occurredAt: now, rawText: "등산 좋아해",
        labelEvidence: [.init(label: .event, score: nil, source: .gemmaHeader,
            classifierVersion: "test")], createdAt: now)
    let one = try ChatDataExport(recentEntries: [], activeMemories: [memory], exportedAt: now)
    let oneJSON = try JSONSerialization.jsonObject(with: one.jsonData()) as! [String: Any]
    #expect((oneJSON["recentEntries"] as! [Any]).isEmpty)
    #expect((oneJSON["longTermMemories"] as! [Any]).count == 1)

    let empty = try ChatDataExport(recentEntries: [], activeMemories: [], exportedAt: now)
    let emptyJSON = try JSONSerialization.jsonObject(with: empty.jsonData()) as! [String: Any]
    #expect((emptyJSON["recentEntries"] as! [Any]).isEmpty)
    #expect((emptyJSON["longTermMemories"] as! [Any]).isEmpty)
}

@Test
func chatDataExportIncludesHomeLineInConversationOrder() throws {
    var session = RoutedPersonaSessionContext(maximumTurnCount: 20)
    try session.appendHomeLine(id: "home-1", text: "밤에 안 잤구나?")
    _ = try session.beginRequest(requestID: "request-1", userMessage: "어떻게 알았어?")
    try session.finishRequest(requestID: "request-1", status: .completed, assistantMessage: "표정이 보여.")
    let exported = try ChatDataExport(recentEntries: session.recentEntries, activeMemories: [])
    let json = try JSONSerialization.jsonObject(with: exported.jsonData()) as! [String: Any]
    let entries = json["recentEntries"] as! [[String: Any]]
    #expect(entries.map { $0["kind"] as! String } == ["homeLine", "request"])
    #expect(entries[0]["text"] as? String == "밤에 안 잤구나?")
    #expect(entries[1]["userMessage"] as? String == "어떻게 알았어?")
}

@Test
func chatDataExportRejectsMalformedActiveMemoryInsteadOfSilentlyOmittingIt() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let malformed = MemoryObservation(id: "broken", turnID: "turn", sessionID: "session",
        sequence: 0, scope: .init(userID: "local-user", characterID: "elena"),
        occurredAt: now, rawText: "기억", labelEvidence: [], createdAt: now)
    #expect(throws: ChatDataExportError.invalidMemory("broken")) {
        try ChatDataExport(recentEntries: [], activeMemories: [malformed])
    }
}

@Test
func temporaryChatExportFileIsRemovedAfterSharing() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("petai-export-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = try TemporaryChatDataExportFile(data: Data("{}".utf8), temporaryRoot: root)
    #expect(try Data(contentsOf: file.fileURL) == Data("{}".utf8))
    try file.remove()
    #expect(!FileManager.default.fileExists(atPath: file.fileURL.path))
}
