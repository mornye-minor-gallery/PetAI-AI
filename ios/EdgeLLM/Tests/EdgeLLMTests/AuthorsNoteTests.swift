import Foundation
import Testing
@testable import EdgeLLM

private struct NoteFixtures: Decodable {
    struct Case: Decodable {
        struct Expected: Decodable { let text: String; let active: Bool; let disabled: Bool; let position: AuthorsNotePosition; let depth: Int; let role: DialoguePromptRole; let interval: Int }
        let id: String; let settings: AuthorsNoteSettings; let userMessages: Int; let expected: Expected
    }
    struct Depth: Decodable { let depth: Int; let order: [String] }
    let cases: [Case]; let depths: [Depth]
    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: #require(Bundle.module.url(forResource: "authors-note-upstream", withExtension: "json"))))
    }
}

@Test func authorsNoteMatchesOriginalSettingsAndIntervals() throws {
    for fixture in try NoteFixtures.load().cases {
        let result = try AuthorsNoteResolver.resolve(fixture.settings, userMessageNumber: fixture.userMessages)
        #expect(result.text == fixture.expected.text, "\(fixture.id)")
        #expect(result.active == fixture.expected.active, "\(fixture.id)")
        #expect((result.state == .disabled) == fixture.expected.disabled, "\(fixture.id)")
        #expect(result.position == fixture.expected.position)
        #expect(result.depth == fixture.expected.depth)
        #expect(result.role == fixture.expected.role)
        #expect(result.interval == fixture.expected.interval)
    }
}

@Test func authorsNoteDepthMatchesOriginalMessageOrder() throws {
    let prompts = try RoutedPersonaPromptRegistry().load()
    let turns: [RoutedPersonaSessionContext.Turn] = [.init(role: .user, text: "사용자1"), .init(role: .assistant, text: "답변1"), .init(role: .user, text: "사용자2"), .init(role: .assistant, text: "답변2")]
    let session = RoutedPersonaSessionContext(turns: turns)
    for fixture in try NoteFixtures.load().depths {
        let result = try DialoguePromptComposer.prepare(input: .init(persona: prompts, history: session.turns, currentMessage: "현재질문", session: session.snapshot(requestID: "depth"), authorsNote: .init(defaults: .init(text: "노트", depth: fixture.depth))))
        var remaining = result.userPrompt[...]
        for text in fixture.order {
            let range = try #require(remaining.range(of: text), "depth \(fixture.depth): \(text)")
            remaining = remaining[range.upperBound...]
        }
        #expect(result.trace.insertions.first?.requestedRole == .system)
        #expect(result.trace.insertions.first?.deliveredRole == .user)
    }
}

@Test func authorsNoteUsesCumulativeClockAndRetrySnapshot() throws {
    var session = RoutedPersonaSessionContext(maximumTurnCount: 2)
    for _ in 0..<11 { session.appendExchange(userMessage: "과거", assistantMessage: "답변") }
    let settings = AuthorsNoteSettings(defaults: .init(text: "상기", interval: 3))
    let snapshot = try session.snapshot(requestID: "pending")
    let prompts = try RoutedPersonaPromptRegistry().load()
    let input = DialoguePromptInput(persona: prompts, history: snapshot.history, currentMessage: "질문", session: snapshot, authorsNote: settings)
    let first = try DialoguePromptComposer.prepare(input: input)
    #expect(first.trace.authorsNote?.active == true)
    #expect(first.trace.authorsNote?.userMessageNumber == 12)
    #expect(try DialoguePromptComposer.prepare(input: input).userPrompt == first.userPrompt)
    #expect(session.completedUserMessages == 11)
    try session.commit(snapshot, userMessage: "질문", assistantMessage: "답변")
    #expect(try session.commit(snapshot, userMessage: "질문", assistantMessage: "답변") == .alreadyCommitted)
    #expect(try AuthorsNoteResolver.resolve(settings, userMessageNumber: session.snapshot(requestID: "next").currentUserMessageNumber).active == false)
}

@Test func authorsNoteEmptyDueRemainsEligibleForWorldInfo() throws {
    let resolution = try AuthorsNoteResolver.resolve(.init(allowWorldInfoScan: true), userMessageNumber: 1)
    #expect(resolution.active)
    #expect(resolution.allowWorldInfoScan)
    #expect(resolution.text.isEmpty)
}

@Test func authorsNoteRequiresSnapshotAndRejectsInvalidSettings() throws {
    let prompts = try RoutedPersonaPromptRegistry().load()
    #expect(throws: DialoguePromptError.missingSessionSnapshot) {
        try DialoguePromptComposer.prepare(input: .init(persona: prompts, currentMessage: "질문", authorsNote: .init()))
    }
    #expect(throws: AuthorsNoteError.invalidInterval) {
        try AuthorsNoteResolver.resolve(.init(defaults: .init(interval: -1)), userMessageNumber: 1)
    }
    #expect(throws: AuthorsNoteError.invalidDepth) {
        try AuthorsNoteResolver.resolve(.init(chat: .init(depth: 10001)), userMessageNumber: 1)
    }
}

@Test func authorsNoteSystemPlacementsAndAbsentNotePreserveContract() throws {
    let prompts = try RoutedPersonaPromptRegistry().load()
    let snapshot = try RoutedPersonaSessionContext().snapshot(requestID: "system")
    let baseline = try DialoguePromptComposer.prepare(input: .init(persona: prompts, currentMessage: "질문"))
    for position in [AuthorsNotePosition.beforeSystem, .afterSystem] {
        let result = try DialoguePromptComposer.prepare(input: .init(persona: prompts, currentMessage: "질문", session: snapshot, authorsNote: .init(defaults: .init(text: "상기문", position: position))))
        #expect(result.systemPrompt == (position == .beforeSystem ? "상기문\n\n" + baseline.systemPrompt : baseline.systemPrompt + "\n\n상기문"))
        #expect(result.userPrompt == baseline.userPrompt)
        #expect(result.trace.insertions.first?.deliveredRole == .system)
    }
    let empty = try DialoguePromptComposer.prepare(input: .init(persona: prompts, currentMessage: "질문", session: snapshot, authorsNote: .init()))
    #expect(empty.modelInput == baseline.modelInput)
}

@Test func authorsNoteRejectsAmbiguousInsertionIdentifiers() throws {
    let prompts = try RoutedPersonaPromptRegistry().load()
    let snapshot = try RoutedPersonaSessionContext().snapshot(requestID: "collision")
    for id in ["authorsNote", "history.1"] {
        #expect(throws: DialoguePromptError.invalidInsertionID(id)) {
            try DialoguePromptComposer.prepare(input: .init(persona: prompts, currentMessage: "질문",
                insertions: [.init(id: id, source: .worldInfo, text: "참고", placement: .beforeCurrent)],
                session: snapshot, authorsNote: .init(defaults: .init(text: "상기"))))
        }
    }
}
