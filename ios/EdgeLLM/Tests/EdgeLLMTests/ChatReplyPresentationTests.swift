import Foundation
import Testing
@testable import EdgeLLM

@Suite struct ChatReplyPresentationTests {
    @Test(arguments: [
        ("오늘은 책을 읽었어.", "smile"), ("고마워, 반가워.", "wink"),
        ("조금 쑥스러워.", "shy"), ("깜짝 놀랐어!", "surprise"),
        ("고마워. 그런데 정말이야?", "surprise"), ("", "smile"),
        ("<face=shy> 별빛 +999999", "smile")
    ])
    func usesOnlyVisibleTextDisplayRules(input: (String, String)) {
        let value = ChatReplyPresentation.dialogue(visibleText: input.0)
        #expect(value.face == input.1)
        #expect(value.kind == "dialogue")
    }

    @Test func encodesAllowlistedMetadataWithoutCurrency() throws {
        let data = try JSONEncoder().encode(ChatReplyPresentation.dialogue(visibleText: "부끄러워."))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["schemaVersion", "source", "kind", "face"])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["source"] as? String == "native-visible-text-v1")
        #expect(try JSONDecoder().decode(ChatReplyPresentation.self, from: data).face == "shy")
    }

    @Test func toolCompletionIsExplicitlyNotDialogue() {
        #expect(ChatReplyPresentation.tool.kind == "tool")
        #expect(ChatReplyPresentation.tool.face == "smile")
    }
}
