import Foundation
import Testing
@testable import EdgeLLM

private struct RelationshipTokenMeasurer: DialogueTokenMeasuring {
    let identifier = "relationship-test"
    func countTokens(_ text: String) async throws -> Int { text.utf16.count }
    func measureInput(_ input: DialogueModelInput) async throws -> Int {
        input.messages.reduce(0) { $0 + $1.text.utf16.count }
    }
}

@Test func relationshipLoreUsesThreeRecentMessages() async throws {
    var rules = WorldInfoEntryRules()
    rules.excludeRecursion = true
    rules.preventRecursion = true
    let entry = WorldInfoEntry(id: "relation.sibling", keys: ["동생", "미나"],
        content: "미나는 캐릭터의 동생이다.", position: .afterCharacter,
        scanDepth: 3, matchWholeWords: false, rules: rules)
    let settings = WorldInfoSettings(tokenBudget: 512, entries: [entry])
    let cases: [([String], Bool)] = [
        (["점심 뭐 먹을까?"], false),
        (["동생 요즘 뭐하고 지내?"], true),
        (["미나는 뭐 해?"], true),
        (["나 있잖아 동생이 밥먹자고 했다? 근데 안 감"], true),
        (["걔도 좋아해?", "같이 지내고 있어.", "동생은 뭐 해?"], true),
        (["점심 먹자", "그래", "안녕", "동생은 뭐 해?"], false)
    ]
    for (messages, expected) in cases {
        let selected = try await WorldInfoEngine.select(settings: settings,
            messages: messages, note: nil, measurer: RelationshipTokenMeasurer())
        #expect(selected.selected.contains { $0.id == entry.id } == expected)
    }
}
