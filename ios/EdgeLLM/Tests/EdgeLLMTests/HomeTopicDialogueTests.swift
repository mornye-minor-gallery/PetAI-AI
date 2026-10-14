import Foundation
import XCTest
@testable import EdgeLLM

final class HomeTopicDialogueTests: XCTestCase {
    let opening = "천문대 기록 장치를 자동화하면 기록 담당자는 어떻게 될까?"

    func testGuidanceSurvivesRestartWithoutBecomingVisibleSpeech() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topic-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DialogueSessionFileStore(fileURL: directory.appendingPathComponent("recent.json"))
        var session = RoutedPersonaSessionContext()
        let topic = HomeTopicContext(id: "automation", characterID: "fixture", guidance: "편리함과 고용을 함께 생각한다.")
        try store.recordHomeLine(in: &session, id: "offer-1", text: opening, topic: topic)
        var restored = try XCTUnwrap(store.load())
        let snapshot = try restored.beginRequest(requestID: "question", userMessage: "새로운 일을 맡으면 되잖아.")
        XCTAssertEqual(snapshot.history, [.init(role: .assistant, text: opening)])
        XCTAssertEqual(snapshot.topicContext, topic)
        XCTAssertEqual(restored.chatTurns.count, 1)
    }

    func testTopicGuidanceUsesDynamicSystemContextAndKeepsPrefix() throws {
        let persona = try testPersona()
        var session = RoutedPersonaSessionContext()
        let topic = HomeTopicContext(id: "automation", characterID: "fixture", guidance: "기록 담당자의 재교육을 생각한다.")
        try session.appendHomeLine(id: "offer-1", text: opening, topic: topic)
        let snapshot = try session.snapshot(requestID: "question")
        func compose(_ context: HomeTopicContext?) throws -> PreparedDialogue {
            try DialoguePromptComposer.prepare(input: .init(persona: persona,
                history: snapshot.history, currentMessage: "편리해지는 게 더 중요해.",
                session: snapshot, topicGuidance: context?.promptText))
        }
        let plain = try compose(nil)
        let guided = try compose(snapshot.topicContext)
        XCTAssertEqual(plain.modelInput.initialMessages.prefix(2), guided.modelInput.initialMessages.prefix(2))
        XCTAssertEqual(guided.modelInput.messages.map(\.role), [.system, .user, .system, .user])
        XCTAssertTrue(guided.modelInput.initialMessages[1].text.contains("캐릭터: " + opening))
        XCTAssertFalse(guided.modelInput.initialMessages[1].text.contains(topic.guidance))
        XCTAssertTrue(guided.modelInput.initialMessages[2].text.contains(topic.guidance))
        XCTAssertEqual(guided.tokenSections.filter { $0.id == "topic" }.count, 1)
        XCTAssertEqual(plain.modelInput.currentUserMessage, guided.modelInput.currentUserMessage)
    }

    func testCompactionRemovesGuidanceWithTheCarriedEntryBeforePrefill() throws {
        var session = RoutedPersonaSessionContext()
        let topic = HomeTopicContext(id: "automation", characterID: "fixture", guidance: "화두 전용 자료")
        try session.appendHomeLine(id: "offer-1", text: opening, topic: topic)
        let snapshot = try session.snapshot(requestID: "question")
        let prepared = try DialoguePromptComposer.prepare(input: .init(persona: testPersona(),
            history: snapshot.history, currentMessage: "왜?", session: snapshot, topicGuidance: topic.promptText))
        let retained = prepared.contextTemplate.input(entries: session.contextEntries, summary: nil)
        XCTAssertTrue(retained.messages.contains { $0.text.contains(topic.guidance) })
        let compacted = prepared.contextTemplate.input(entries: [], summary: "이전에는 자동화를 이야기했다.")
        XCTAssertFalse(compacted.messages.contains { $0.text.contains(topic.guidance) })
        XCTAssertEqual(retained.initialMessages.first, compacted.initialMessages.first)
        XCTAssertNil(snapshot.replacingContext(entries: [], summary: "요약").topicContext)
    }

    func testOrdinaryHomeLineClearsPreviousTopicGuidance() throws {
        var session = RoutedPersonaSessionContext()
        try session.appendHomeLine(id: "offer-1", text: opening,
            topic: HomeTopicContext(id: "automation", characterID: "fixture", guidance: "보조 자료"))
        try session.appendHomeLine(id: "ordinary", text: "오늘은 일찍 왔네.")
        XCTAssertNil(try session.snapshot(requestID: "question").topicContext)
    }

    func testTopicLimitIncludesTheSystemHeadingAndRejectsOversizedSupport() async throws {
        let topic = HomeTopicContext(id: "automation", characterID: "fixture", guidance: "짧은 근거")
        let text = try XCTUnwrap(topic.promptText)
        let limits = DialoguePromptLimits(fixedTokens: 4000, loreTokens: 512, topicTokens: text.count - 1,
            stateTokens: 1000, questionTokens: 300, questionCharacters: 500)
        let budget = DialogueTokenBudget(memoryTokens: 512, contextTokens: 8192, outputTokens: 512,
            limits: limits)
        do {
            _ = try await DialoguePromptComposer.prepare(input: .init(persona: testPersona(),
                currentMessage: "왜?", topicGuidance: text), tokenBudget: budget, measurer: CompactionCounter())
            XCTFail("Oversized topic support must not bypass its independent component limit")
        } catch let error as DialogueInputLimitError {
            XCTAssertEqual(error, .component(id: "topic", actual: text.count, maximum: text.count - 1))
        }
    }

    func testGuidanceDoesNotOutliveItsRecentEntry() throws {
        var session = RoutedPersonaSessionContext(maximumTurnCount: 2)
        try session.appendHomeLine(id: "offer-1", text: opening,
            topic: HomeTopicContext(id: "automation", characterID: "fixture", guidance: "보조 자료"))
        session.appendExchange(userMessage: "첫 질문", assistantMessage: "첫 답변")
        XCTAssertNil(try session.snapshot(requestID: "next").topicContext)
    }

    func testRepeatCarryMustMatchBothSpeechAndGuidance() throws {
        var session = RoutedPersonaSessionContext()
        let topic = HomeTopicContext(id: "automation", characterID: "fixture", guidance: "보조 자료")
        XCTAssertEqual(try session.appendHomeLine(id: "offer-1", text: opening, topic: topic), .committed)
        XCTAssertEqual(try session.appendHomeLine(id: "offer-1", text: opening, topic: topic), .alreadyCommitted)
        XCTAssertThrowsError(try session.appendHomeLine(id: "offer-1", text: opening,
            topic: HomeTopicContext(id: "other", characterID: "fixture", guidance: "다른 자료")))
        XCTAssertEqual(session.turns.count, 1)
    }

    func testExportKeepsTopicMetadataSeparateFromSpeech() throws {
        let topic = HomeTopicContext(id: "automation", characterID: "fixture", guidance: "보조 자료")
        var session = RoutedPersonaSessionContext()
        try session.appendHomeLine(id: "offer-1", text: opening, topic: topic)
        let export = try ChatDataExport(sessions: ["fixture": session], activeMemories: [])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ChatDataExport.self, from: export.jsonData())
        XCTAssertEqual(restored.conversations.first?.recentEntries.first?.text, opening)
        XCTAssertEqual(restored.conversations.first?.recentEntries.first?.topic, topic)
    }
}
