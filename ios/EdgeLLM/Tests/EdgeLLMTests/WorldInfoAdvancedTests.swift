import Foundation
import Testing
@testable import EdgeLLM

private struct AdvancedMeter: DialogueTokenMeasuring {
    let identifier = "utf16"
    func countTokens(_ text: String) async throws -> Int { text.utf16.count }
    func measureInput(_ input: DialogueModelInput) async throws -> Int { input.messages.reduce(0) { $0 + $1.text.utf16.count } }
}
@Test func worldInfoRecursionAndDepthExpansion() async throws {
    var scan = WorldInfoScanRules(); scan.recursive = true
    let entries: [WorldInfoEntry] = [.init(id: "a", keys: ["start"], content: "next"), .init(id: "b", keys: ["next"], content: "end")]
    let result = try await WorldInfoEngine.select(settings: .init(tokenBudget: 100, entries: entries, rules: scan), messages: ["start"], note: nil, measurer: AdvancedMeter())
    #expect(result.selected.map(\.id) == ["a", "b"])
    scan.recursive = false; scan.minimumActivations = 1
    let expanded = try await WorldInfoEngine.select(settings: .init(tokenBudget: 100, entries: entries, scanDepth: 1, rules: scan), messages: ["empty", "start"], note: nil, measurer: AdvancedMeter())
    #expect(expanded.selected.map(\.id) == ["a"])
}
@Test func worldInfoProbabilityAndGroupsAreReproducible() async throws {
    var rules = WorldInfoEntryRules(); rules.groups = ["place"]; rules.groupOverride = true
    var rejected = WorldInfoEntryRules(); rejected.probability = 0
    let settings = WorldInfoSettings(tokenBudget: 100, entries: [
        .init(id: "a", content: "A", constant: true, order: 200, rules: rules),
        .init(id: "b", content: "B", constant: true, rules: rules),
        .init(id: "c", content: "C", constant: true, rules: rejected)])
    let result = try await WorldInfoEngine.select(settings: settings, messages: [], note: nil, measurer: AdvancedMeter())
    #expect(result.selected.map(\.id) == ["a"])
}

@Test func worldInfoCommitIsTransactionalAndSurvivesHistoryRetention() async throws {
    var session = RoutedPersonaSessionContext(maximumTurnCount: 2)
    let snapshot = try session.snapshot(requestID: "first")
    var rule = WorldInfoEntryRules(); rule.sticky = 20
    let settings = WorldInfoSettings(tokenBudget: 100, entries: [.init(id: "a", content: "A", constant: true, rules: rule)])
    let result = try await WorldInfoEngine.select(settings: settings, messages: ["hello"], note: nil, measurer: AdvancedMeter())
    #expect(session.worldInfoState.sticky.isEmpty)
    let proposal = WorldInfoTransaction(state: result.nextState, text: result.textContext)
    #expect(try session.commit(snapshot, userMessage: "hello", assistantMessage: "hi", worldInfo: proposal) == .committed)
    #expect(try session.commit(snapshot, userMessage: "hello", assistantMessage: "hi", worldInfo: proposal) == .alreadyCommitted)
    #expect(throws: DialogueSessionError.conflictingCommit) { try session.commit(snapshot, userMessage: "hello", assistantMessage: "hi") }
    for _ in 0..<4 { session.appendExchange(userMessage: "x", assistantMessage: "y") }
    #expect(session.turns.count == 4)
    #expect(try session.snapshot(requestID: "next").currentMessageNumber == 11)
    #expect(session.worldInfoState.sticky["a"] != nil)
    session.removeAll()
    #expect(session.worldInfoState.sticky.isEmpty)
    #expect(throws: DialogueSessionError.staleSnapshot) { try session.commit(snapshot, userMessage: "hello", assistantMessage: "hi", worldInfo: proposal) }
}

@Test func worldInfoVectorRetrievalUsesDocumentAndQueryInputs() async throws {
    var rules = WorldInfoEntryRules(); rules.vectorized = true
    let matches = try await WorldInfoVectorSearch.search(entries: [
        .init(id: "a", content: "A", rules: rules), .init(id: "b", content: "B", rules: rules)],
        newestMessages: ["current", "previous", "excluded"], settings: .init(queryMessages: 2, maximumEntries: 1, threshold: 0.5),
        embedQuery: { text in #expect(text == "current\nprevious"); return [1, 0] },
        embedDocument: { $0 == "A" ? [1, 0] : [0, 1] })
    #expect(matches.map(\.id) == ["a"])
    #expect(throws: WorldInfoVectorError.self) { try WorldInfoVectorSearch.cosine([0, 0], [1, 0]) }
}

@Test func worldInfoComposerResolvesOutletAndRandomWithoutChangingUserText() async throws {
    var outlet = WorldInfoEntryRules(); outlet.outlet = "weather"
    let settings = WorldInfoSettings(tokenBudget: 500, entries: [
        .init(id: "outlet", content: "맑음", constant: true, position: .outlet, rules: outlet),
        .init(id: "random", content: "{{random::a::b}}", constant: true)])
    let session = try RoutedPersonaSessionContext().snapshot(requestID: "outlet")
    let prepared = try await DialoguePromptComposer.prepare(input: .init(persona: testPersona(),
        currentMessage: "{{setvar::x::bad}}", session: session,
        authorsNote: .init(defaults: .init(text: "날씨: {{outlet::weather}}", depth: 0)), worldInfo: settings),
        tokenBudget: .init(memoryTokens: 0, contextTokens: 100_000, outputTokens: 1000), measurer: AdvancedMeter())
    #expect(prepared.userText.contains("날씨: 맑음"))
    #expect(prepared.userText.contains("{{setvar::x::bad}}"))
    #expect(prepared.worldInfoTransaction?.text.localVariables["x"] == nil)
    #expect(prepared.worldInfoTransaction?.text.outlets["weather"] == "맑음")
}
@Test func worldInfoGroupScoreRequiresEverySecondaryForAndAll() throws {
    let entry = WorldInfoEntry(id: "a", keys: ["a"], content: "", secondaryKeys: ["b", "c"], secondaryLogic: .andAll, constant: true)
    #expect(try WorldInfoEngine.score(entry, buffer: "a b", settings: .init(tokenBudget: 10, entries: [])) == 1)
}

@Test func worldInfoStickyBypassesRecursionDelay() async throws {
    var rule = WorldInfoEntryRules(); rule.sticky = 4; rule.delayUntilRecursion = 2
    let entry = WorldInfoEntry(id: "a", keys: ["absent"], content: "A", rules: rule)
    let temporal = try WorldInfoEngine.temporalEntry(entry)
    let state = WorldInfoState(sticky: ["a": .init(hash: temporal.hash, start: 1, end: 5, protected: false)])
    var context = WorldInfoContext(); context.messageNumber = 3
    let result = try await WorldInfoEngine.select(settings: .init(tokenBudget: 100, entries: [entry]), messages: ["none"], note: nil,
        measurer: AdvancedMeter(), context: context, state: state)
    #expect(result.selected.map(\.id) == ["a"])
}
@Test func worldInfoDepthGroupingPreservesSingleNewlinesAndRoles() async throws {
    var rule = WorldInfoEntryRules(); rule.depth = 1; rule.role = .assistant
    let selected = try await WorldInfoEngine.select(settings: .init(tokenBudget: 100, entries: [
        .init(id: "a", content: "A", constant: true, position: .inChat, rules: rule),
        .init(id: "b", content: "B", constant: true, position: .inChat, rules: rule)]), messages: [], note: nil, measurer: AdvancedMeter())
    let projection = WorldInfoPromptProjection(selection: selected, note: nil)
    #expect(projection.insertions.count == 1)
    #expect(projection.insertions.first?.text == "B\nA")
    #expect(projection.insertions.first?.role == .assistant)
}
@Test func worldInfoLibraryPrioritySurvivesSelectionBudget() async throws {
    let books = ["chat":"{\"entries\":{\"0\":{\"uid\":0,\"content\":\"chat\",\"constant\":true,\"order\":1}}}",
                 "global":"{\"entries\":{\"0\":{\"uid\":0,\"content\":\"global\",\"constant\":true,\"order\":999}}}"]
    let settings = WorldInfoSettings(tokenBudget: 7, entries: [], library: .init(books: books, global: ["global"], chat: "chat"))
    let result = try await WorldInfoEngine.select(settings: settings, messages: [], note: nil, measurer: AdvancedMeter())
    #expect(result.selected.map(\.id) == ["chat.0"])
}
@Test func worldInfoReplacementMacrosExpandOnlyMatchedText() async throws {
    var rule = WorldInfoEntryRules(); rule.replacements = [.init(pattern: "A", replacement: "{{char}}")]
    let selected = try await WorldInfoEngine.select(settings: .init(tokenBudget: 100, entries: [
        .init(id: "a", content: "A", constant: true, rules: rule)]), messages: [], note: nil,
        measurer: AdvancedMeter(), textContext: .init(char: "엘레나"))
    #expect(selected.selected.first?.content == "엘레나")
}

@Test func vectorEnabledForAllActivatesUnmarkedEntries() async throws {
    var rules = WorldInfoScanRules(); rules.vector = .init(enabledForAll:true)
    var context = WorldInfoContext(); context.vectorMatches = ["unmarked"]
    let result = try await WorldInfoEngine.select(settings:.init(tokenBudget:100,entries:[.init(id:"unmarked",keys:["absent"],content:"lore")],rules:rules),
        messages:["question"],note:nil,measurer:AdvancedMeter(),context:context)
    #expect(result.selected.map(\.id) == ["unmarked"])
}
