import Foundation

/// Persisted intervals use the number of scan messages, including the current user input.
/// A turn number is not interchangeable with this count: a user/assistant pair adds two.
public struct WorldInfoState: Codable, Equatable, Sendable {
    public var sticky: [String: WorldInfoTimedEffect]
    public var cooldown: [String: WorldInfoTimedEffect]

    public init(sticky: [String: WorldInfoTimedEffect] = [:], cooldown: [String: WorldInfoTimedEffect] = [:]) {
        self.sticky = sticky
        self.cooldown = cooldown
    }
}

public struct WorldInfoTimedEffect: Codable, Equatable, Sendable {
    public let hash: String
    public let start: Int
    public let end: Int
    public let protected: Bool

    public init(hash: String, start: Int, end: Int, protected: Bool) {
        self.hash = hash
        self.start = start
        self.end = end
        self.protected = protected
    }
}

/// The caller supplies a stable hash of the complete entry configuration, not Swift's Hasher.
/// Zero disables a duration. Negative durations are rejected by prepare, including in dry runs.
public struct WorldInfoTemporalEntry: Equatable, Sendable {
    public let id: String
    public let hash: String
    public let sticky: Int
    public let cooldown: Int
    public let delay: Int

    public init(id: String, hash: String, sticky: Int = 0, cooldown: Int = 0, delay: Int = 0) {
        self.id = id
        self.hash = hash
        self.sticky = sticky
        self.cooldown = cooldown
        self.delay = delay
    }
}

public enum WorldInfoTemporalError: Error, Equatable, Sendable {
    case invalidMessageNumber
    case invalidID
    case invalidHash(String)
    case duplicateID(String)
    case invalidDuration(String)
    case intervalOverflow(String)
    case invalidRecord(String)
    case messageNumberMismatch
    case unpreparedEntry(String)
}

public struct WorldInfoTemporalSnapshot: Equatable, Sendable {
    public let activeSticky: Set<String>
    public let activeCooldown: Set<String>
    public let delayed: Set<String>
    public let nextState: WorldInfoState
    fileprivate let entries: [WorldInfoTemporalEntry]
    fileprivate let messageNumber: Int
    fileprivate let dryRun: Bool
}

/// Pure preparation and finalization keep cancellation and persistence under the caller's control.
/// Period boundaries follow SillyTavern 06bde939fb1e9c4c8d8641d810f0a916b5bce127.
public enum WorldInfoTemporalRules {
    public static func prepare(
        state: WorldInfoState,
        entries: [WorldInfoTemporalEntry],
        messageNumber: Int,
        dryRun: Bool = false
    ) throws -> WorldInfoTemporalSnapshot {
        guard messageNumber >= 0 else { throw WorldInfoTemporalError.invalidMessageNumber }
        try validate(entries, messageNumber: messageNumber)
        try validate(state.sticky)
        try validate(state.cooldown)
        var nextState = state
        var activeSticky = Set<String>()
        var activeCooldown = Set<String>()
        let delayed = Set(entries.filter { messageNumber < $0.delay }.map(\.id))

        if !dryRun {
            // Upstream resolves records by hash, although it stores them by ID. A changed hash
            // therefore leaves an inactive old record blocking a replacement until expiry.
            // Sorting gives deterministic traversal without relying on Dictionary iteration order.
            for id in state.sticky.keys.sorted() {
                guard let effect = state.sticky[id] else { continue }
                if messageNumber <= effect.start && !effect.protected {
                    nextState.sticky.removeValue(forKey: id)
                    continue
                }
                guard let entry = entries.first(where: { $0.hash == effect.hash }) else {
                    if messageNumber >= effect.end { nextState.sticky.removeValue(forKey: id) }
                    continue
                }
                guard entry.sticky > 0 else {
                    nextState.sticky.removeValue(forKey: id)
                    continue
                }
                if messageNumber >= effect.end {
                    nextState.sticky.removeValue(forKey: id)
                    if entry.cooldown > 0 {
                        // Delayed observation intentionally starts a full cooldown NOW, rather
                        // than at the old sticky end. Protection survives same-count regeneration
                        // and even rewinding before start, matching the upstream interval check.
                        nextState.cooldown[entry.id] = try effectFor(
                            entry, duration: entry.cooldown, at: messageNumber, protected: true)
                        activeCooldown.insert(entry.id)
                    }
                } else {
                    activeSticky.insert(entry.id)
                }
            }
            // Sticky expiry can overwrite cooldown records, so inspect the resulting dictionary.
            let cooldowns = nextState.cooldown
            for id in cooldowns.keys.sorted() {
                guard let effect = cooldowns[id] else { continue }
                if messageNumber <= effect.start && !effect.protected {
                    nextState.cooldown.removeValue(forKey: id)
                    continue
                }
                guard let entry = entries.first(where: { $0.hash == effect.hash }) else {
                    if messageNumber >= effect.end { nextState.cooldown.removeValue(forKey: id) }
                    continue
                }
                if entry.cooldown == 0 || messageNumber >= effect.end {
                    nextState.cooldown.removeValue(forKey: id)
                } else {
                    activeCooldown.insert(entry.id)
                }
            }
        }

        return WorldInfoTemporalSnapshot(activeSticky: activeSticky, activeCooldown: activeCooldown,
            delayed: delayed, nextState: nextState, entries: entries, messageNumber: messageNumber, dryRun: dryRun)
    }

    /// Only entries accepted after grouping, probability and budget checks start intervals.
    /// The returned state is a proposal; this function does not commit it to a session.
    public static func finish(
        _ snapshot: WorldInfoTemporalSnapshot,
        selected: [WorldInfoTemporalEntry],
        messageNumber: Int
    ) throws -> WorldInfoState {
        guard messageNumber == snapshot.messageNumber else { throw WorldInfoTemporalError.messageNumberMismatch }
        try validate(selected, messageNumber: messageNumber)
        for entry in selected where !snapshot.entries.contains(entry) {
            throw WorldInfoTemporalError.unpreparedEntry(entry.id)
        }
        guard !snapshot.dryRun else { return snapshot.nextState }
        var state = snapshot.nextState
        for entry in selected {
            // Both intervals start on initial activation. Upstream sticky suppression and
            // inclusion-group behavior are handled by selection, not changed by this state layer.
            if entry.sticky > 0 && state.sticky[entry.id] == nil {
                state.sticky[entry.id] = try effectFor(entry, duration: entry.sticky, at: messageNumber)
            }
            if entry.cooldown > 0 && state.cooldown[entry.id] == nil {
                state.cooldown[entry.id] = try effectFor(entry, duration: entry.cooldown, at: messageNumber)
            }
        }
        return state
    }

    private static func effectFor(
        _ entry: WorldInfoTemporalEntry, duration: Int, at messageNumber: Int, protected: Bool = false
    ) throws -> WorldInfoTimedEffect {
        let (end, overflow) = messageNumber.addingReportingOverflow(duration)
        guard !overflow else { throw WorldInfoTemporalError.intervalOverflow(entry.id) }
        return .init(hash: entry.hash, start: messageNumber, end: end, protected: protected)
    }

    private static func validate(_ entries: [WorldInfoTemporalEntry], messageNumber: Int) throws {
        var ids = Set<String>()
        for entry in entries {
            guard !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorldInfoTemporalError.invalidID
            }
            guard !entry.hash.isEmpty else { throw WorldInfoTemporalError.invalidHash(entry.id) }
            guard ids.insert(entry.id).inserted else { throw WorldInfoTemporalError.duplicateID(entry.id) }
            guard entry.sticky >= 0, entry.cooldown >= 0, entry.delay >= 0 else {
                throw WorldInfoTemporalError.invalidDuration(entry.id)
            }
            guard !messageNumber.addingReportingOverflow(entry.sticky).overflow,
                  !messageNumber.addingReportingOverflow(entry.cooldown).overflow else {
                throw WorldInfoTemporalError.intervalOverflow(entry.id)
            }
        }
    }

    private static func validate(_ records: [String: WorldInfoTimedEffect]) throws {
        for (id, record) in records {
            // Typed state deliberately rejects malformed persisted intervals rather than
            // silently deleting them as upstream's loose JavaScript metadata cleanup does.
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !record.hash.isEmpty, record.start >= 0, record.end > record.start else {
                throw WorldInfoTemporalError.invalidRecord(id)
            }
        }
    }
}
