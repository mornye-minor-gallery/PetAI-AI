import Foundation
import Testing
@testable import EdgeLLM

private struct WorldInfoFixtures: Decodable {
    struct Case: Decodable {
        struct Note: Decodable { let text: String; let active: Bool; let scan: Bool }
        struct Expected: Decodable { let selected: [String]; let before: String; let after: String; let note: String }
        let id: String; let settings: WorldInfoSettings; let messages: [String]; let note: Note?
        let emptyTokens: Int; let expected: Expected; let context: WorldInfoContext?
    }
    let cases: [Case]
}
private struct FixtureTokenMeasurer: DialogueTokenMeasuring {
    let identifier = "test-utf16"
    var emptyTokens = 0
    func countTokens(_ text: String) async throws -> Int { text.isEmpty ? emptyTokens : text.utf16.count }
    func measureInput(_ input: DialogueModelInput) async throws -> Int { input.systemPrompt.utf16.count + input.userPrompt.utf16.count }
}

@Test func worldInfoMatchesPinnedUpstreamSelection() async throws {
    let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "world-info-upstream", withExtension: "json")))
    for test in try JSONDecoder().decode(WorldInfoFixtures.self, from: data).cases {
        let note = try test.note.map {
            try AuthorsNoteResolver.resolve(.init(defaults: .init(text: $0.text, interval: $0.active ? 1 : 0), allowWorldInfoScan: $0.scan), userMessageNumber: 1)
        }
        let result = try await WorldInfoEngine.select(settings: test.settings, messages: test.messages,
            note: note, measurer: FixtureTokenMeasurer(emptyTokens: test.emptyTokens), context: test.context ?? .init())
        // Known upstream splice(-1) bug: removing an already removed shared group
        // member deletes an unrelated candidate. Keep the oracle unchanged as evidence.
        let overlapFix = test.id == "advanced-group-overlap"
        if overlapFix { #expect(test.expected.selected == ["a"]) }
        #expect(result.selected.map(\.id) == (overlapFix ? ["a", "b"] : test.expected.selected), "\(test.id)")
        let projected = WorldInfoPromptProjection(selection: result, note: note)
        #expect(projected.insertions.first(where: { $0.placement == .beforePersona })?.text ?? "" == test.expected.before, "\(test.id)")
        #expect(projected.insertions.first(where: { $0.placement == .afterPersona })?.text ?? "" == (overlapFix ? "b\na" : test.expected.after), "\(test.id)")
        #expect(projected.note?.text ?? "" == test.expected.note, "\(test.id)")
    }
}

@Test func worldInfoRejectsUnsupportedSettingsRatherThanIgnoringThem() throws {
    for extra in ["\"recursive\":true", "\"sticky\":3", "\"unknown\":true"] {
        let data = Data("{\"tokenBudget\":100,\"entries\":[],\(extra)}".utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorldInfoSettings.self, from: data) }
    }
}

@Test func worldInfoNeedsActualTokenizerAndRejectsMalformedEntries() async throws {
    let prompts = try testPersona()
    let settings = WorldInfoSettings(tokenBudget: 20, entries: [.init(id: "one", keys: ["/test/i"], content: "text")])
    #expect(throws: WorldInfoError.tokenMeasurerRequired) {
        try DialoguePromptComposer.prepare(input: .init(persona: prompts, currentMessage: "test", worldInfo: settings))
    }
    let regex = try await WorldInfoEngine.select(settings: settings, messages: ["TEST"], note: nil, measurer: FixtureTokenMeasurer())
    #expect(regex.selected.map(\.id) == ["one"])
    await #expect(throws: WorldInfoError.duplicateID("one")) {
        try await WorldInfoEngine.select(settings: .init(tokenBudget: 20, entries: [
            .init(id: "one", keys: ["a"], content: "a"), .init(id: "one", keys: ["b"], content: "b")]), messages: [], note: nil, measurer: FixtureTokenMeasurer())
    }
}

@Test func worldInfoComposerKeepsMemorySeparateAndPlacesCharacterAndNoteContent() async throws {
    let prompts = try testPersona()
    let context = RoutedPersonaSessionContext(turns: [.init(role: .user, text: "서울"), .init(role: .assistant, text: "대화")])
    let settings = WorldInfoSettings(tokenBudget: 100, entries: [
        .init(id: "before", keys: ["서울"], content: "캐릭터앞", position: .beforeCharacter),
        .init(id: "after", keys: ["서울"], content: "캐릭터뒤", position: .afterCharacter),
        .init(id: "note", keys: ["서울"], content: "노트앞", position: .beforeNote)
    ], scanDepth: 3, includeNames: false)
    let prepared = try await DialoguePromptComposer.prepare(input: .init(persona: prompts,
        history: context.turns, currentMessage: "현재질문", session: context.snapshot(requestID: "test"),
        authorsNote: .init(defaults: .init(text: "상기문", depth: 1)), worldInfo: settings),
        tokenBudget: .init(memoryTokens: 0, contextTokens: 100_000, outputTokens: 1000), measurer: FixtureTokenMeasurer())
    #expect(prepared.trace.worldInfo?.entries.filter { $0.reason == .selected }.count == 3)
    #expect(prepared.trace.systemSections == ["persona", "responseContract", "nameRule"])
    #expect(prepared.trace.userSections == ["history", "worldInfo.beforeCharacter", "worldInfo.afterCharacter", "profile", "authorsNote", "currentMessage"])
    #expect(prepared.userPrompt.hasSuffix("노트앞\n상기문\n\n현재질문"))
    #expect(prepared.trace.tokenBudget?.sections.contains { $0.id == "worldInfo.beforeCharacter" } == true)
    #expect(context.turns.count == 2)
}

@Test func cacheStableSystemSectionsPrecedeEveryRequestDynamicSection() async throws {
    let prompts = try testPersona()
    let session = RoutedPersonaSessionContext()
    let settings = WorldInfoSettings(tokenBudget: 100, entries: [
        .init(id: "before", content: "동적 세계관", constant: true, position: .beforeCharacter)
    ])
    let prepared = try await DialoguePromptComposer.prepare(input: .init(
        persona: prompts, activeCard: "동적 장면", profile: .init(userName: "테스터", dailySteps: [
            .init(date: "2026-09-23", steps: 1234)
        ]), currentMessage: "질문", session: session.snapshot(requestID: "stable-prefix"),
        worldInfo: settings, exampleDialogue: "세션 고정 대화 예시"),
        tokenBudget: .init(memoryTokens: 0, contextTokens: 100_000, outputTokens: 100),
        measurer: FixtureTokenMeasurer())

    #expect(prepared.trace.systemSections == ["persona", "responseContract", "nameRule", "dialogue.examples"])
    #expect(prepared.trace.userSections == ["worldInfo.beforeCharacter", "scene", "profile", "currentMessage"])
}

@Test func worldInfoAndNoteChangesRetainTheHistoryPrefix() async throws {
    let prompts = try testPersona()
    let session = RoutedPersonaSessionContext(turns: [
        .init(role: .user, text: "과거 질문"), .init(role: .assistant, text: "과거 답변")
    ])
    let snapshot = try session.snapshot(requestID: "context-prefix")
    let settings = WorldInfoSettings(tokenBudget: 100, entries: [
        .init(id: "travel", keys: ["여행"], content: "여행 문맥", position: .beforeCharacter),
        .init(id: "reading", keys: ["독서"], content: "독서 문맥", position: .beforeCharacter)
    ], scanDepth: 1, includeNames: false)
    func prepare(_ message: String, note: String) async throws -> PreparedDialogue {
        try await DialoguePromptComposer.prepare(input: .init(
            persona: prompts, history: snapshot.history, currentMessage: message, session: snapshot,
            authorsNote: .init(defaults: .init(text: note, position: .afterSystem)), worldInfo: settings),
            tokenBudget: .init(memoryTokens: 0, contextTokens: 100_000, outputTokens: 100),
            measurer: FixtureTokenMeasurer())
    }
    let travel = try await prepare("여행 계획", note: "첫 상기문")
    let reading = try await prepare("독서 계획", note: "둘째 상기문")
    let prefix = "## 최근 대화\n사용자: 과거 질문\n캐릭터: 과거 답변"

    #expect(travel.systemPrompt == reading.systemPrompt)
    for prepared in [travel, reading] {
        #expect(prepared.userPrompt.hasPrefix(prefix))
        #expect(prepared.trace.userSections == ["history", "worldInfo.beforeCharacter", "profile", "authorsNote", "currentMessage"])
        #expect(prepared.trace.tokenBudget?.sections.filter { $0.role == .user }.map(\.id) == prepared.trace.userSections)
    }
    #expect(travel.userPrompt.contains("여행 문맥"))
    #expect(travel.userPrompt.contains("첫 상기문"))
    #expect(reading.userPrompt.contains("독서 문맥"))
    #expect(reading.userPrompt.contains("둘째 상기문"))
}

@Test func worldInfoNoteInactiveIsSelectedButNotInserted() async throws {
    let note = try AuthorsNoteResolver.resolve(.init(defaults: .init(interval: 0)), userMessageNumber: 1)
    let selected = try await WorldInfoEngine.select(settings: .init(tokenBudget: 100, entries: [
        .init(id: "top", content: "노트내용", constant: true, position: .beforeNote)]),
        messages: [], note: note, measurer: FixtureTokenMeasurer())
    let projection = WorldInfoPromptProjection(selection: selected, note: note)
    #expect(projection.trace.entries[0].reason == .selected)
    #expect(projection.trace.entries[0].delivery == .noteInactive)
    #expect(projection.note?.insertion == nil)
    #expect(projection.insertions.isEmpty)
}

@Test func worldInfoFillsAbsentNoteAndDoesNotRecursivelyScanSelectedContent() async throws {
    let prompts = try testPersona()
    let snapshot = try RoutedPersonaSessionContext().snapshot(requestID: "empty-note")
    let settings = WorldInfoSettings(tokenBudget: 100, entries: [
        .init(id: "first", keys: ["서울"], content: "연쇄키", position: .beforeNote),
        .init(id: "second", keys: ["연쇄키"], content: "재귀결과")], includeNames: false)
    let result = try await DialoguePromptComposer.prepare(input: .init(persona: prompts, currentMessage: "서울",
        session: snapshot, worldInfo: settings), tokenBudget: .init(memoryTokens: 0, contextTokens: 100_000, outputTokens: 100),
        measurer: FixtureTokenMeasurer())
    #expect(result.userPrompt.contains("연쇄키"))
    #expect(!result.systemPrompt.contains("재귀결과"))
    #expect(!result.userPrompt.contains("재귀결과"))
    #expect(result.trace.worldInfo?.entries.last?.reason == .noPrimaryMatch)
}

@Test func worldInfoSpeakerNamesAreAnExplicitSearchOption() async throws {
    let prompts = try testPersona()
    let context = RoutedPersonaSessionContext(turns: [.init(role: .assistant, text: "안녕")])
    let entry = WorldInfoEntry(id: "name", keys: ["엘레나"], content: "이름검색결과")
    for names in [false, true] {
        let result = try await DialoguePromptComposer.prepare(input: .init(persona: prompts,
            history: context.turns, currentMessage: "질문", session: context.snapshot(requestID: "names"),
            worldInfo: .init(tokenBudget: 100, entries: [entry], includeNames: names)),
            tokenBudget: .init(memoryTokens: 0, contextTokens: 100_000, outputTokens: 100), measurer: FixtureTokenMeasurer())
        #expect(result.userPrompt.contains("이름검색결과") == names)
    }
}
