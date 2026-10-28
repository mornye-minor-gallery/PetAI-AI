import Foundation
import Testing
@testable import EdgeLLM

@Test func chatExportIncludesTheRetainedSummary() throws {
    var session = RoutedPersonaSessionContext()
    try session.compact(retaining: [], summary: "지난 대화의 요약", modelIdentifier: "test")
    let exported = try ChatDataExport(sessions: ["elena": session], activeMemories: [])
    let json = try JSONSerialization.jsonObject(with: exported.jsonData()) as! [String: Any]
    let conversations = json["conversations"] as! [[String: Any]]
    #expect(conversations[0]["sessionSummary"] as? String == "지난 대화의 요약")
}

@Test func chatExportKeepsBothCharactersConversationsSeparate() throws {
    var elena = RoutedPersonaSessionContext()
    var lucia = RoutedPersonaSessionContext()
    try elena.appendHomeLine(id: "home-elena", text: "잘 잤어?")
    try lucia.appendHomeLine(id: "home-lucia", text: "일어났어?")
    let exported = try ChatDataExport(sessions: ["lucia": lucia, "elena": elena], activeMemories: [])
    let json = try JSONSerialization.jsonObject(with: exported.jsonData()) as! [String: Any]
    let conversations = json["conversations"] as! [[String: Any]]
    #expect(conversations.compactMap { $0["characterID"] as? String } == ["elena", "lucia"])
    #expect(((conversations[0]["recentEntries"] as! [[String: Any]])[0]["id"] as? String) == "home-elena")
    #expect(((conversations[1]["recentEntries"] as! [[String: Any]])[0]["id"] as? String) == "home-lucia")
}

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
    let diary = DailyDiary(characterID: "elena", localDate: "2026-09-27",
        title: "산책한 날", body: "산책했어요.", completedAt: now)
    let exported = try ChatDataExport(sessions: ["elena": session], activeMemories: [memory],
        diaries: [diary], exportedAt: now)
    let json = try JSONSerialization.jsonObject(with: exported.jsonData()) as! [String: Any]
    let conversations = json["conversations"] as! [[String: Any]]
    let turns = conversations[0]["recentEntries"] as! [[String: Any]]
    let memories = json["longTermMemories"] as! [[String: Any]]

    #expect(json["formatVersion"] as? Int == 6)
    // AI 기본법 제31조 2항: 서비스 밖으로 나가는 파일 안에 생성형 AI가 만든 항목을 밝힌다.
    let notice = json["generatedContentNotice"] as? String
    #expect(notice?.contains("생성형 AI") == true)
    #expect(notice?.contains("assistantMessage") == true)
    #expect(notice?.contains("sessionSummary") == true)
    #expect(notice?.contains("diaries") == true)
    #expect(conversations[0]["characterID"] as? String == "elena")
    #expect((json["diaries"] as? [[String: Any]])?.first?["title"] as? String == "산책한 날")
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
    let one = try ChatDataExport(sessions: [:], activeMemories: [memory], exportedAt: now)
    let oneJSON = try JSONSerialization.jsonObject(with: one.jsonData()) as! [String: Any]
    #expect((oneJSON["conversations"] as! [Any]).isEmpty)
    #expect((oneJSON["longTermMemories"] as! [Any]).count == 1)

    let empty = try ChatDataExport(sessions: [:], activeMemories: [], exportedAt: now)
    let emptyJSON = try JSONSerialization.jsonObject(with: empty.jsonData()) as! [String: Any]
    #expect((emptyJSON["conversations"] as! [Any]).isEmpty)
    #expect((emptyJSON["longTermMemories"] as! [Any]).isEmpty)
}

@Test
func chatDataExportIncludesHomeLineInConversationOrder() throws {
    var session = RoutedPersonaSessionContext(maximumTurnCount: 20)
    try session.appendHomeLine(id: "home-1", text: "밤에 안 잤구나?")
    _ = try session.beginRequest(requestID: "request-1", userMessage: "어떻게 알았어?")
    try session.finishRequest(requestID: "request-1", status: .completed, assistantMessage: "표정이 보여.")
    let exported = try ChatDataExport(sessions: ["elena": session], activeMemories: [])
    let json = try JSONSerialization.jsonObject(with: exported.jsonData()) as! [String: Any]
    let entries = (json["conversations"] as! [[String: Any]])[0]["recentEntries"] as! [[String: Any]]
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
        try ChatDataExport(sessions: [:], activeMemories: [malformed])
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
