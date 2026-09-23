import Testing
@testable import EdgeLLM

@Test func invalidVariableMacrosThrowAndPreserveState() throws {
    let invalid = [
        "{{variable}}", "{{variable::}}", "{{variable::   }}",
        "{{#variable}}body{{/variable}}", "{{#variable::}}body{{/variable}}",
        "{{variable::name}}", "{{variable::.}}", "{{variable::$}}",
        "{{.}}", "{{$}}"
    ]
    for text in invalid {
        var context = WorldInfoTextContext(localVariables: ["kept": "old"])
        let original = context
        #expect(throws: WorldInfoTextError.self) {
            try WorldInfoText.expand("{{setvar::kept::new}}{{setglobalvar::new::value}}" + text, context: &context)
        }
        #expect(context == original)
        #expect(try WorldInfoText.expand("{{.kept}}", context: &context) == "old")
    }
}

@Test func validVariableShorthandStillReadsAndWrites() throws {
    var context = WorldInfoTextContext()
    #expect(try WorldInfoText.expand("{{.count = 1}}{{.count += 2}}{{variable::.count}}", context: &context) == "3")
    #expect(try WorldInfoText.expand("{{$name = value}}{{variable::$name}}", context: &context) == "value")
}

@Test func invalidVariableNoteLeavesSessionUnchanged() throws {
    var session = RoutedPersonaSessionContext()
    let snapshot = try session.snapshot(requestID: "invalid")
    let before = session.checkpoint()
    #expect(throws: WorldInfoTextError.self) {
        try DialoguePromptComposer.prepare(input: .init(
            persona: RoutedPersonaPromptSet(core: "테스트 캐릭터", sceneCards: [:]), profile: .init(characterName: "엘레나"),
            currentMessage: "안녕", session: snapshot,
            authorsNote: .init(defaults: .init(text: "{{setvar::visits::9}}{{variable}}", depth: 0))))
    }
    #expect(session.checkpoint() == before)
    let good = try DialoguePromptComposer.prepare(input: .init(
        persona: RoutedPersonaPromptSet(core: "테스트 캐릭터", sceneCards: [:]), profile: .init(characterName: "엘레나"),
        currentMessage: "안녕", session: snapshot,
        authorsNote: .init(defaults: .init(text: "{{incvar::visits}}", depth: 0))))
    try session.commit(snapshot, userMessage: "안녕", assistantMessage: "반가워", worldInfo: good.worldInfoTransaction)
    #expect(session.worldInfoText.localVariables["visits"] == "1")
}

@Test func failedPromptRetryRetainsHistoryClockAndWorldInfo() throws {
    let state = WorldInfoState(
        sticky: ["scene": .init(hash: "v1", start: 19, end: 25, protected: false)],
        cooldown: ["other": .init(hash: "v1", start: 19, end: 27, protected: false)])
    var session = RoutedPersonaSessionContext(worldInfoState: state,
        worldInfoText: .init(localVariables: ["visits": "3"]))
    for i in 0..<12 { session.appendExchange(userMessage: "질문 \(i)", assistantMessage: "답변 \(i)") }
    let before = session.checkpoint()
    let prompts = RoutedPersonaPromptSet(core: "테스트 캐릭터", sceneCards: [:])
    let failed = try session.snapshot(requestID: "failed")
    #expect(throws: WorldInfoTextError.self) {
        try DialoguePromptComposer.prepare(input: .init(persona: prompts,
            history: failed.history, currentMessage: "다음 질문", session: failed,
            authorsNote: .init(defaults: .init(text: "{{incvar::visits}}{{variable}}", depth: 0))))
    }
    #expect(session.checkpoint() == before)
    let retry = try session.snapshot(requestID: "retry")
    #expect(retry.history.count == 24)
    #expect(retry.currentUserMessageNumber == 13)
    #expect(retry.currentMessageNumber == 25)
    #expect(retry.worldInfoState == state)
    let prepared = try DialoguePromptComposer.prepare(input: .init(persona: prompts,
        history: retry.history, currentMessage: "다음 질문", session: retry,
        authorsNote: .init(defaults: .init(text: "{{incvar::visits}}", depth: 0))))
    #expect(prepared.userPrompt.contains("질문 11"))
    #expect(prepared.userPrompt.contains("답변 11"))
    #expect(try session.commit(retry, userMessage: "다음 질문", assistantMessage: "다음 답변",
        worldInfo: prepared.worldInfoTransaction) == .committed)
    #expect(try session.commit(retry, userMessage: "다음 질문", assistantMessage: "다음 답변",
        worldInfo: prepared.worldInfoTransaction) == .alreadyCommitted)
    #expect(session.completedUserMessages == 13)
    #expect(session.worldInfoText.localVariables["visits"] == "4")
    #expect(session.worldInfoState == state)
}
