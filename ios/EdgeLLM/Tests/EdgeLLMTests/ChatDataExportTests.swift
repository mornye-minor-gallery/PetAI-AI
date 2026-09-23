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
    let exported = try ChatDataExport(recentTurns: session.chatTurns, activeMemories: [memory], exportedAt: now)
    let json = try JSONSerialization.jsonObject(with: exported.jsonData()) as! [String: Any]
    let turns = json["recentTurns"] as! [[String: Any]]
    let memories = json["longTermMemories"] as! [[String: Any]]

    #expect(json["formatVersion"] as? Int == 1)
    #expect(turns.map { $0["requestID"] as! String } == ["turn-3", "turn-4"])
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
    let one = try ChatDataExport(recentTurns: [], activeMemories: [memory], exportedAt: now)
    let oneJSON = try JSONSerialization.jsonObject(with: one.jsonData()) as! [String: Any]
    #expect((oneJSON["recentTurns"] as! [Any]).isEmpty)
    #expect((oneJSON["longTermMemories"] as! [Any]).count == 1)

    let empty = try ChatDataExport(recentTurns: [], activeMemories: [], exportedAt: now)
    let emptyJSON = try JSONSerialization.jsonObject(with: empty.jsonData()) as! [String: Any]
    #expect((emptyJSON["recentTurns"] as! [Any]).isEmpty)
    #expect((emptyJSON["longTermMemories"] as! [Any]).isEmpty)
}

@Test
func chatDataExportRejectsMalformedActiveMemoryInsteadOfSilentlyOmittingIt() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let malformed = MemoryObservation(id: "broken", turnID: "turn", sessionID: "session",
        sequence: 0, scope: .init(userID: "local-user", characterID: "elena"),
        occurredAt: now, rawText: "기억", labelEvidence: [], createdAt: now)
    #expect(throws: ChatDataExportError.invalidMemory("broken")) {
        try ChatDataExport(recentTurns: [], activeMemories: [malformed])
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
