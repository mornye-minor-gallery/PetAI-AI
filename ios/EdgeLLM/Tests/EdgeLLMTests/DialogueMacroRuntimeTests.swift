import Foundation
import Testing
@testable import EdgeLLM

@Test func dialogueMacrosUseNestedLexicalAndScopedSemantics() throws {
    var context = WorldInfoTextContext(user: "민아", char: "엘레나")
    #expect(try WorldInfoText.expand("{{getvar::x}}{{setvar::x::1}}", context: &context) == "")
    #expect(try WorldInfoText.expand("{{if::{{hasvar::x}}}}{{char}}{{else}}없음{{/if}}", context: &context) == "엘레나")
    #expect(try WorldInfoText.expand("{{setvar::y}}안녕 {{user}}{{/setvar}}{{getvar::y}}", context: &context) == "안녕 민아")
    #expect(try WorldInfoText.expand("{{.x += 2}}{{.x}}", context: &context) == "3")
}

@Test func standaloneAuthorsNoteExpandsAndCommitsVariables() throws {
    var session = RoutedPersonaSessionContext()
    let snapshot = try session.snapshot(requestID: "note")
    let prepared = try DialoguePromptComposer.prepare(input: .init(
        persona: testPersona(), profile: .init(characterName: "엘레나"),
        currentMessage: "안녕", session: snapshot,
        authorsNote: .init(defaults: .init(text: "{{char}} {{incvar::visits}}", depth: 0))))
    #expect(prepared.userPrompt.contains("엘레나 1"))
    try session.commit(snapshot, userMessage: "안녕", assistantMessage: "반가워", worldInfo: prepared.worldInfoTransaction)
    #expect(session.worldInfoText.localVariables["visits"] == "1")
}

@Test func nativeVariablesKeepNumericAndStringValuesDistinct() throws {
    var context = WorldInfoTextContext(localVariables: ["n":"0x10", "s":"cat"])
    let result = try WorldInfoText.expand("{{getvar::n}}/{{addvar::s::fish}}{{getvar::s}}/{{getvar::missing}}", context: &context)
    #expect(result == "16/catfish/")
    #expect(context.localVariables["s"] == "catfish")
}

@Test func nativeMacrosMatchPinnedUpstreamResultsAndState() throws {
    struct Fixture: Decodable {
        struct Case: Decodable {
            let id: String; let text: String; let context: WorldInfoTextContext; let expected: String
            let localVariables: [String:String]; let globalVariables: [String:String]; let randomIndex: Int
        }
        let cases: [Case]
    }
    let url = try #require(Bundle.module.url(forResource: "native-macro-upstream", withExtension: "json"))
    for example in try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:url)).cases {
        var context = example.context
        let result = try WorldInfoText.expand(example.text, context: &context)
        #expect(result == example.expected, "\(example.id): \(example.text)")
        #expect(context.localVariables == example.localVariables, "\(example.id)")
        #expect(context.globalVariables == example.globalVariables, "\(example.id)")
        #expect(context.randomIndex == example.randomIndex, "\(example.id)")
    }
}

@Test func extremeMacroInputsThrowWithoutCommittingState() throws {
    for text in ["{{roll::1d1+9223372036854775807}}", "{{time::UTC9223372036854775807}}"] {
        var context = WorldInfoTextContext(randomRolls:[0])
        context.runtime = ["nowMilliseconds":.number(0)]
        let original = context
        #expect(throws:WorldInfoTextError.self) { try WorldInfoText.expand(text,context:&context) }
        #expect(context == original)
    }
    var context = WorldInfoTextContext()
    let deeplyNested = String(repeating:"{{if true}}",count:1024)+"x"+String(repeating:"{{/if}}",count:1024)
    #expect(throws:WorldInfoTextError.self) { try WorldInfoText.expand(deeplyNested,context:&context) }
}

@Test func negativeGreetingIndexReturnsEmptyWithoutOverflow() throws {
    var context = WorldInfoTextContext()
    context.runtime = ["character":.object(["alternateGreetings":.array([])])]
    #expect(try WorldInfoText.expand("{{greeting::-9223372036854775808}}",context:&context) == "")
}
