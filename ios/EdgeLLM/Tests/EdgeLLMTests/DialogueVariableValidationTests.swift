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
