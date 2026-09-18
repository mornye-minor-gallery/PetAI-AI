import CryptoKit
import Foundation
import Testing
@testable import EdgeLLM

private func promptMemory(_ text: String, index: Int) -> RetrievedMemoryObservation {
    let date = Date(timeIntervalSince1970: 0)
    return RetrievedMemoryObservation(observation: MemoryObservation(
        id: "fixture-\(index)", turnID: "fixture-\(index)", sessionID: "fixture",
        sequence: index, scope: MemoryScope(userID: "synthetic", characterID: "synthetic"),
        occurredAt: date, rawText: text, labelEvidence: [], createdAt: date), score: 1, rank: index)
}

@Test func composerPreservesFrozenWorkerPrompts() throws {
    let url = try #require(Bundle.module.url(forResource: "dialogue-prompt-baseline", withExtension: "json"))
    let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let cases = try #require(document["cases"] as? [[String: Any]])
    let prompts = try RoutedPersonaPromptRegistry().load()
    for sample in cases {
        let request = try #require(sample["request"] as? [String: Any])
        let rawConfig = try #require(request["configuration"] as? [String: Any])
        let persona = try JSONDecoder().decode(PersonaResponseConfiguration.self, from: JSONSerialization.data(withJSONObject: rawConfig))
        let placement = try #require(NameRulePlacement(rawValue: rawConfig["nameRulePlacement"] as! String))
        var session = RoutedPersonaSessionContext()
        for exchange in request["history"] as! [[String: String]] {
            session.appendExchange(userMessage: exchange["user"]!, assistantMessage: exchange["assistant"]!)
        }
        let memories = (request["memories"] as! [String]).enumerated().map { promptMemory($0.element, index: $0.offset) }
        let prepared = try DialoguePromptComposer.prepare(input: DialoguePromptInput(
            persona: prompts, activeCard: nil,
            profile: UserProfileContext(characterName: request["characterName"] as! String),
            history: session.turns, memories: memories, currentMessage: request["userMessage"] as! String
        ), policy: DialoguePromptPolicy(persona: persona, nameRulePlacement: placement))
        let outputs = ["system_prompt": prepared.systemPrompt, "user_prompt": prepared.userPrompt,
                       "unpositioned_user_prompt": prepared.unpositionedUserPrompt,
                       "current_input": prepared.memoryAugmentedInput, "name_instruction": prepared.nameInstruction]
        for (key, expected) in sample["sha256"] as! [String: String] {
            let digest = SHA256.hash(data: Data(outputs[key]!.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == expected, "case \(request["id"]!) \(key)")
        }
        let stats = sample["memory_stats"] as! [String: Int]
        #expect(prepared.trace.insertedMemoryCount == stats["inserted_count"])
        #expect(prepared.trace.insertedMemoryBytes == stats["inserted_bytes"])
        #expect(prepared.responseConfiguration == persona)
        #expect(session.turns.count == ((request["history"] as! [[String: String]]).isEmpty ? 0 : 20))
    }
}

@Test func composerRejectsInactiveNamePlacement() throws {
    let input = DialoguePromptInput(persona: try RoutedPersonaPromptRegistry().load(), currentMessage: "안녕")
    #expect(throws: DialoguePromptError.self) {
        try DialoguePromptComposer.prepare(input: input, policy: .init(
            persona: .init(enforceCharacterName: false), nameRulePlacement: .beforeCurrent))
    }
}

@Test func composerReportsExcludedMemoryWithoutChangingSources() throws {
    let memories = [promptMemory("너무 긴 기억", index: 0), promptMemory("차", index: 1), promptMemory("  ", index: 2)]
    let input = DialoguePromptInput(persona: try RoutedPersonaPromptRegistry().load(), memories: memories, currentMessage: "질문")
    let result = try DialoguePromptComposer.prepare(input: input, policy: .init(memoryByteBudget: 5))
    #expect(result.trace.memories.map(\.reason) == [.budgetExceeded, .included, .empty])
    #expect(result.trace.insertedMemoryCount == 1)
    #expect(result.trace.insertedMemoryBytes == 5)
    #expect(input.memories.count == 3)
    #expect(result.userPrompt.contains("- 차"))
}

@Test func composerTraceMatchesPlacementAndRetainsOutputContract() throws {
    let input = DialoguePromptInput(persona: try RoutedPersonaPromptRegistry().load(),
        activeCard: "장면 규칙", memories: [promptMemory("기억", index: 0)], currentMessage: "아영아?")
    for placement in NameRulePlacement.allCases {
        let result = try DialoguePromptComposer.prepare(input: input, policy: .init(nameRulePlacement: placement))
        #expect(result.trace.systemSections.contains("responseContract"))
        #expect(result.trace.systemSections.contains("scene"))
        #expect(result.trace.systemSections.contains("nameRule") == (placement == .system))
        let expected = placement == .system ? ["memories", "currentMessage"] :
            placement == .beforeCurrent ? ["memories", "nameRule", "currentMessage"] : ["memories", "currentMessage", "nameRule"]
        #expect(result.trace.userSections == expected)
        #expect(result.trace.userBytes == result.userPrompt.utf8.count)
        #expect(result.responseConfiguration.memoryClassification)
    }
}

@Test func composerRejectsInvalidByteBudget() throws {
    let input = DialoguePromptInput(persona: try RoutedPersonaPromptRegistry().load(), currentMessage: "질문")
    #expect(throws: DialoguePromptError.invalidMemoryByteBudget) {
        try DialoguePromptComposer.prepare(input: input, policy: .init(memoryByteBudget: 0))
    }
}
