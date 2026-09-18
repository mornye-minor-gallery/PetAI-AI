import Foundation
import Testing
@testable import EdgeLLM

private let originalLorebook = Data(#"""
{"name":"original title","extensions":{"owner":"local"},"entries":{"9":{"uid":9,"key":["cat"],"keysecondary":["sleep"],"content":"hello","comment":"memo","selective":true,"selectiveLogic":3,"position":4,"order":120,"disable":false,"useProbability":true,"probability":45,"group":"pets, home","groupOverride":true,"groupWeight":70,"useGroupScoring":false,"sticky":3,"cooldown":2,"delay":4,"delayUntilRecursion":true,"excludeRecursion":true,"preventRecursion":true,"characterFilter":{"names":["elena"],"tags":["friend"],"isExclude":true},"matchPersonaDescription":true,"role":2,"depth":3,"triggers":["normal"],"extensions":{"source":"import"}},"2":{"uid":2,"key":[],"keysecondary":["ignored"],"selective":false,"constant":true,"content":"second","position":1,"order":120}}}
"""#.utf8)

@Test func worldInfoLorebookImportsFlatOriginalFieldsAndPreservesJSON() throws {
    let book = try WorldInfoLorebook(data: originalLorebook, name: "pets")
    #expect(book.entries.map(\.id) == ["pets.2", "pets.9"])
    let entry = try #require(book.entries.last)
    #expect(entry.keys == ["cat"])
    #expect(entry.secondaryLogic == .andAll)
    #expect(entry.position == .inChat)
    #expect(entry.rules.role == .assistant)
    #expect(entry.rules.probability == 45)
    #expect(entry.rules.groups == ["pets", "home"])
    #expect(entry.rules.delayUntilRecursion == 1)
    #expect(entry.rules.characterNames == ["elena"])
    #expect(entry.rules.characterTags == ["friend"])
    #expect(entry.rules.excludeCharacters == true)
    #expect(entry.rules.scanFields == ["personaDescription"])
    #expect(book.entries[0].secondaryKeys.isEmpty)
    #expect(book.preservedMetadataPaths.contains("entries.9.comment"))
    #expect(book.preservedMetadataPaths.contains("entries.9.extensions"))
    let before = try JSONSerialization.jsonObject(with: originalLorebook) as? NSDictionary
    let after = try JSONSerialization.jsonObject(with: book.exportData()) as? NSDictionary
    #expect(before == after)
}

@Test func worldInfoLorebookEditsKeepMetadataAndUseOriginalFormat() throws {
    let original = try WorldInfoLorebook(data: originalLorebook, name: "pets")
    var entry = try #require(original.entries.last)
    entry.content = "updated"
    let changed = try original.replacing(entry)
    let again = try WorldInfoLorebook(data: changed.exportData(), name: "pets")
    #expect(again.entries.last?.content == "updated")
    let root = try #require(JSONSerialization.jsonObject(with: changed.exportData()) as? [String: Any])
    let objects = try #require(root["entries"] as? [String: [String: Any]])
    #expect(objects["9"]?["comment"] as? String == "memo")
    #expect(objects["9"]?["delayUntilRecursion"] as? Bool == true)
    let originalRoot = try #require(JSONSerialization.jsonObject(with: originalLorebook) as? [String: Any])
    let originalRecords = try #require(originalRoot["entries"] as? [String: [String: Any]])
    #expect(objects["9"]?.count == originalRecords["9"]?.count)
    #expect(objects["9"]?["extensions"] as? [String: String] == ["source": "import"])
    let added = try changed.upserting(.init(id: "pets.10", content: "new", constant: true))
    #expect(added.entries.map(\.id) == ["pets.2", "pets.9", "pets.10"])
    #expect(try added.removing(id: "pets.9").entries.map(\.id) == ["pets.2", "pets.10"])
    #expect(original.entries.last?.content == "hello")
}

@Test func worldInfoLorebookRejectsUnknownBehaviorAndBadIdentity() throws {
    #expect(throws: WorldInfoLorebookError.unsupportedField("entries.1.newActivationMode")) {
        try WorldInfoLorebook(data: Data(#"{"entries":{"1":{"uid":1,"content":"x","newActivationMode":true}}}"#.utf8), name: "book")
    }
    #expect(throws: WorldInfoLorebookError.invalidField("entries.1.uid")) {
        try WorldInfoLorebook(data: Data(#"{"entries":{"1":{"uid":2,"content":"x"}}}"#.utf8), name: "book")
    }
    #expect(throws: WorldInfoLorebookError.invalidField("entries.1.position")) {
        try WorldInfoLorebook(data: Data(#"{"entries":{"1":{"uid":1,"position":99}}}"#.utf8), name: "book")
    }
}

private func lorebook(_ name: String, order: Int = 100) throws -> WorldInfoLorebook {
    try WorldInfoLorebook(data: Data("{\"entries\":{\"0\":{\"uid\":0,\"content\":\"\(name)\",\"order\":\(order)}}}".utf8), name: name)
}

@Test func worldInfoLorebookLibraryUsesScopeAndStrategyOrder() throws {
    let library = try WorldInfoLibrary(lorebooks: [lorebook("global", order: 200), lorebook("character", order: 300), lorebook("chat", order: 1), lorebook("persona", order: 2)])
    #expect(try library.select(global: ["global"], character: ["character"], chat: "chat", persona: "persona").map(\.id)
        == ["chat.0", "persona.0", "character.0", "global.0"])
    #expect(try library.select(global: ["global"], character: ["character"], strategy: .globalFirst).map(\.id)
        == ["global.0", "character.0"])
    #expect(try library.select(global: ["global"], character: ["character"], strategy: .characterFirst).map(\.id)
        == ["character.0", "global.0"])
}

@Test func worldInfoLorebookLibraryDeduplicatesAccordingToUpstreamScopePrecedence() throws {
    let library = try WorldInfoLibrary(lorebooks: [lorebook("shared"), lorebook("character")])
    let result = try library.select(global: ["shared"], character: ["shared", "character"], chat: "shared", persona: "shared", strategy: .characterFirst)
    #expect(result.map(\.id) == ["character.0", "shared.0"])
    #expect(try library.select(character: ["shared"], chat: "shared", persona: "shared").map(\.id) == ["shared.0"])
    #expect(throws: WorldInfoLorebookError.missingBook("missing")) { try library.select(global: ["missing"]) }
    #expect(throws: WorldInfoLorebookError.duplicateBook("shared")) { try WorldInfoLibrary(lorebooks: [lorebook("shared"), lorebook("shared")]) }
}

@Test func worldInfoLorebookReplacingDormantSecondaryKeysEnablesTheirMatching() throws {
    let book = try WorldInfoLorebook(data: originalLorebook, name: "pets")
    let changed = try book.replacing(.init(id: "pets.2", content: "second", secondaryKeys: ["active"], constant: true, order: 120))
    #expect(changed.entries.first?.secondaryKeys == ["active"])
}

@Test func worldInfoLorebookMapsEveryOriginalPositionAndLogic() throws {
    let positions: [WorldInfoEntry.Position] = [.beforeCharacter, .afterCharacter, .beforeNote, .afterNote, .inChat, .beforeExamples, .afterExamples, .outlet]
    let logic: [WorldInfoEntry.SecondaryLogic] = [.andAny, .notAll, .notAny, .andAll]
    for position in positions.indices {
        let data = Data("{\"entries\":{\"0\":{\"uid\":0,\"position\":\(position),\"selectiveLogic\":\(position % 4)}}}".utf8)
        let entry = try #require(WorldInfoLorebook(data: data, name: "all").entries.first)
        #expect(entry.position == positions[position])
        #expect(entry.secondaryLogic == logic[position % 4])
    }
}

@Test func worldInfoLorebookMissingSwitchesDoNotEnableDormantRules() throws {
    let data = Data(#"{"entries":{"0":{"uid":0,"keysecondary":["dormant"],"probability":20}}}"#.utf8)
    let entry = try #require(WorldInfoLorebook(data: data, name: "missing").entries.first)
    #expect(entry.secondaryKeys.isEmpty)
    #expect(entry.rules.probability == nil)
}
