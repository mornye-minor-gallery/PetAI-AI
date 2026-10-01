import Foundation
import Testing
@testable import EdgeLLM

private let timedEntry = WorldInfoTemporalEntry(id: "book.one", hash: "version-1", sticky: 3, cooldown: 2)

private func activatedState(at count: Int = 10, entry: WorldInfoTemporalEntry = timedEntry) throws -> WorldInfoState {
    let snapshot = try WorldInfoTemporalRules.prepare(state: .init(), entries: [entry], messageNumber: count)
    return try WorldInfoTemporalRules.finish(snapshot, selected: [entry], messageNumber: count)
}

@Test func worldInfoTemporalIntervalsAndProtectedCooldownMatchUpstream() throws {
    let initial = try activatedState()
    #expect(initial.sticky[timedEntry.id] == .init(hash: "version-1", start: 10, end: 13, protected: false))
    #expect(initial.cooldown[timedEntry.id]?.end == 12)
    let eleven = try WorldInfoTemporalRules.prepare(state: initial, entries: [timedEntry], messageNumber: 11)
    #expect(eleven.activeSticky == [timedEntry.id])
    #expect(eleven.activeCooldown == [timedEntry.id])
    let twelve = try WorldInfoTemporalRules.prepare(state: eleven.nextState, entries: [timedEntry], messageNumber: 12)
    #expect(twelve.activeSticky == [timedEntry.id])
    #expect(twelve.activeCooldown.isEmpty)
    let thirteen = try WorldInfoTemporalRules.prepare(state: twelve.nextState, entries: [timedEntry], messageNumber: 13)
    #expect(thirteen.activeSticky.isEmpty)
    #expect(thirteen.activeCooldown == [timedEntry.id])
    #expect(thirteen.nextState.cooldown[timedEntry.id] == .init(hash: "version-1", start: 13, end: 15, protected: true))
    let regenerated = try WorldInfoTemporalRules.prepare(state: thirteen.nextState, entries: [timedEntry], messageNumber: 13)
    #expect(regenerated.nextState == thirteen.nextState)
    #expect(regenerated.activeCooldown == [timedEntry.id])
    let fifteen = try WorldInfoTemporalRules.prepare(state: regenerated.nextState, entries: [timedEntry], messageNumber: 15)
    #expect(fifteen.nextState == .init())
}

@Test func worldInfoTemporalRegenerationClearsOrdinaryRecordsAndCanRearm() throws {
    let initial = try activatedState()
    for count in [9, 10] {
        let snapshot = try WorldInfoTemporalRules.prepare(state: initial, entries: [timedEntry], messageNumber: count)
        #expect(snapshot.nextState == .init())
        #expect(snapshot.activeSticky.isEmpty)
        #expect(snapshot.activeCooldown.isEmpty)
    }
    let snapshot = try WorldInfoTemporalRules.prepare(state: initial, entries: [timedEntry], messageNumber: 10)
    #expect(try WorldInfoTemporalRules.finish(snapshot, selected: [timedEntry], messageNumber: 10) == initial)
}

@Test func worldInfoTemporalLateStickyExpiryStartsCooldownAtObservation() throws {
    let snapshot = try WorldInfoTemporalRules.prepare(state: activatedState(), entries: [timedEntry], messageNumber: 20)
    #expect(snapshot.nextState.cooldown[timedEntry.id]?.start == 20)
    #expect(snapshot.nextState.cooldown[timedEntry.id]?.end == 22)
    #expect(snapshot.activeCooldown == [timedEntry.id])
    let rewind = try WorldInfoTemporalRules.prepare(state: snapshot.nextState, entries: [timedEntry], messageNumber: 9)
    #expect(rewind.activeCooldown == [timedEntry.id])
}

@Test func worldInfoTemporalHashChangesRetainOldRecordsUntilTheirExpiry() throws {
    let changed = WorldInfoTemporalEntry(id: timedEntry.id, hash: "version-2", sticky: 3, cooldown: 2)
    let initial = try activatedState()
    let snapshot = try WorldInfoTemporalRules.prepare(state: initial, entries: [changed], messageNumber: 11)
    #expect(snapshot.activeSticky.isEmpty)
    #expect(snapshot.activeCooldown.isEmpty)
    #expect(try WorldInfoTemporalRules.finish(snapshot, selected: [changed], messageNumber: 11) == initial)
    let expired = try WorldInfoTemporalRules.prepare(state: initial, entries: [changed], messageNumber: 13)
    #expect(expired.nextState == .init())
    #expect(expired.activeCooldown.isEmpty)
}

@Test func worldInfoTemporalMissingEntriesDoNotStartCooldownOnExpiry() throws {
    let initial = try activatedState()
    let missing = try WorldInfoTemporalRules.prepare(state: initial, entries: [], messageNumber: 11)
    #expect(missing.nextState == initial)
    let expired = try WorldInfoTemporalRules.prepare(state: initial, entries: [], messageNumber: 13)
    #expect(expired.nextState == .init())
}

@Test func worldInfoTemporalDelayUsesAbsoluteMessageCountIncludingCurrentInput() throws {
    let entry = WorldInfoTemporalEntry(id: "delay", hash: "v1", delay: 4)
    let before = try WorldInfoTemporalRules.prepare(state: .init(), entries: [entry], messageNumber: 3)
    let boundary = try WorldInfoTemporalRules.prepare(state: .init(), entries: [entry], messageNumber: 4)
    #expect(before.delayed == [entry.id])
    #expect(boundary.delayed.isEmpty)
    #expect(before.nextState == .init())
}

@Test func worldInfoTemporalDryRunKeepsStoredStateButStillChecksDelay() throws {
    let entry = WorldInfoTemporalEntry(id: timedEntry.id, hash: timedEntry.hash, sticky: 3, cooldown: 2, delay: 20)
    let initial = try activatedState()
    let snapshot = try WorldInfoTemporalRules.prepare(state: initial, entries: [entry], messageNumber: 10, dryRun: true)
    #expect(snapshot.nextState == initial)
    #expect(snapshot.activeSticky.isEmpty)
    #expect(snapshot.activeCooldown.isEmpty)
    #expect(snapshot.delayed == [entry.id])
    #expect(try WorldInfoTemporalRules.finish(snapshot, selected: [entry], messageNumber: 10) == initial)
}

@Test func worldInfoTemporalOnlySelectedEntriesStartEffectsAndActiveEffectsDoNotExtend() throws {
    let prepared = try WorldInfoTemporalRules.prepare(state: .init(), entries: [timedEntry], messageNumber: 10)
    #expect(try WorldInfoTemporalRules.finish(prepared, selected: [], messageNumber: 10) == .init())
    let initial = try activatedState()
    let eleven = try WorldInfoTemporalRules.prepare(state: initial, entries: [timedEntry], messageNumber: 11)
    #expect(try WorldInfoTemporalRules.finish(eleven, selected: [timedEntry], messageNumber: 11) == initial)
    #expect(prepared.nextState == .init())
}

@Test func worldInfoTemporalDurationOneHasNoSubsequentIntegerActivation() throws {
    let entry = WorldInfoTemporalEntry(id: "one", hash: "v1", sticky: 1)
    let snapshot = try WorldInfoTemporalRules.prepare(state: activatedState(entry: entry), entries: [entry], messageNumber: 11)
    #expect(snapshot.activeSticky.isEmpty)
    #expect(snapshot.nextState == .init())
}

@Test func worldInfoTemporalStateRoundTripsThroughJSON() throws {
    let state = try activatedState()
    let data = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(WorldInfoState.self, from: data) == state)
}

@Test func worldInfoTemporalRejectsInvalidInputsAndOverflow() throws {
    #expect(throws: WorldInfoTemporalError.invalidMessageNumber) {
        try WorldInfoTemporalRules.prepare(state: .init(), entries: [], messageNumber: -1)
    }
    for entry in [WorldInfoTemporalEntry(id: "bad", hash: "v1", sticky: -1),
                  WorldInfoTemporalEntry(id: "bad", hash: "v1", cooldown: -1),
                  WorldInfoTemporalEntry(id: "bad", hash: "v1", delay: -1)] {
        #expect(throws: WorldInfoTemporalError.invalidDuration("bad")) {
            try WorldInfoTemporalRules.prepare(state: .init(), entries: [entry], messageNumber: 0)
        }
    }
    #expect(throws: WorldInfoTemporalError.intervalOverflow(timedEntry.id)) {
        try WorldInfoTemporalRules.prepare(state: .init(), entries: [timedEntry], messageNumber: Int.max)
    }
    #expect(throws: WorldInfoTemporalError.duplicateID(timedEntry.id)) {
        try WorldInfoTemporalRules.prepare(state: .init(), entries: [timedEntry, timedEntry], messageNumber: 0)
    }
    let malformed = WorldInfoState(sticky: ["bad": .init(hash: "v1", start: 3, end: 2, protected: false)])
    #expect(throws: WorldInfoTemporalError.invalidRecord("bad")) {
        try WorldInfoTemporalRules.prepare(state: malformed, entries: [], messageNumber: 0)
    }
}

@Test func worldInfoTemporalFinishRejectsChangedCountOrUnpreparedSelection() throws {
    let snapshot = try WorldInfoTemporalRules.prepare(state: .init(), entries: [timedEntry], messageNumber: 10)
    #expect(throws: WorldInfoTemporalError.messageNumberMismatch) {
        try WorldInfoTemporalRules.finish(snapshot, selected: [timedEntry], messageNumber: 11)
    }
    #expect(throws: WorldInfoTemporalError.unpreparedEntry("other")) {
        try WorldInfoTemporalRules.finish(snapshot, selected: [.init(id: "other", hash: "v1")], messageNumber: 10)
    }
}

@Test func worldInfoTemporalMatchesRecordsByHashRatherThanStorageKey() throws {
    let initial = try activatedState()
    let moved = WorldInfoTemporalEntry(id: "other.key", hash: timedEntry.hash, sticky: 3, cooldown: 2)
    let snapshot = try WorldInfoTemporalRules.prepare(state: initial, entries: [moved], messageNumber: 11)
    #expect(snapshot.activeSticky == [moved.id])
    #expect(snapshot.activeCooldown == [moved.id])
    #expect(snapshot.nextState.sticky[timedEntry.id] != nil)
    let expired = try WorldInfoTemporalRules.prepare(state: initial, entries: [moved], messageNumber: 13)
    #expect(expired.nextState.cooldown[moved.id]?.protected == true)
    #expect(expired.nextState.cooldown[timedEntry.id] == nil)
}

@Test func worldInfoTemporalZeroDurationsClearMatchingRecordsWithoutCooldownTransition() throws {
    let disabled = WorldInfoTemporalEntry(id: timedEntry.id, hash: timedEntry.hash)
    let snapshot = try WorldInfoTemporalRules.prepare(state: activatedState(), entries: [disabled], messageNumber: 11)
    #expect(snapshot.nextState == .init())
    #expect(snapshot.activeSticky.isEmpty)
    #expect(snapshot.activeCooldown.isEmpty)
    #expect(try WorldInfoTemporalRules.finish(snapshot, selected: [disabled], messageNumber: 11) == .init())
}
