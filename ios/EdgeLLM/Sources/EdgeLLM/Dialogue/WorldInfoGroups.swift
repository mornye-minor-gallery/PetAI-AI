import Foundation

extension WorldInfoEngine {
    static func filterGroups(_ candidates: inout [WorldInfoEntry], selected: [WorldInfoEntry], scores: [String: Int], settings: WorldInfoSettings, temporal: WorldInfoTemporalSnapshot, random: inout WorldInfoRandom) {
        var keys: [String] = [], groups: [String: [WorldInfoEntry]] = [:]
        for entry in candidates {
            for key in entry.rules.groups ?? [] where !key.isEmpty {
                if groups[key] == nil { keys.append(key) }
                groups[key, default: []].append(entry)
            }
        }
        func remove(_ entry: WorldInfoEntry) {
            // Intentionally do not copy upstream splice(-1, 1): overlapping groups
            // must never remove an unrelated candidate that was not the target.
            candidates.removeAll { $0.id == entry.id }
        }
        var stickyGroups = Set<String>()
        for key in keys {
            let group = groups[key] ?? []
            if group.contains(where: { temporal.activeSticky.contains($0.id) }) {
                stickyGroups.insert(key)
                for entry in group where !temporal.activeSticky.contains(entry.id) { remove(entry) }
            }
            for entry in group where temporal.activeCooldown.contains(entry.id) || temporal.delayed.contains(entry.id) { remove(entry) }
        }
        for key in keys where !stickyGroups.contains(key) {
            var group = groups[key] ?? []
            if settings.rules.groupScoring == true || group.contains(where: { $0.rules.groupScoring == true }) {
                let maximum = group.map { scores[$0.id] ?? 0 }.max() ?? 0
                let losers = group.filter { ($0.rules.groupScoring ?? settings.rules.groupScoring ?? false) && (scores[$0.id] ?? 0) < maximum }
                for entry in losers { remove(entry) }
                group.removeAll { e in losers.contains { $0.id == e.id } }
            }
            if selected.contains(where: { ($0.rules.groups ?? []).joined(separator: ",") == key }) {
                for entry in group { remove(entry) }; continue
            }
            guard group.count > 1 else { continue }
            let overrides = group.enumerated().filter { $0.element.rules.groupOverride == true }.sorted {
                $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order > $1.element.order
            }
            var winner = overrides.first?.element
            if winner == nil {
                let roll = random.next() * group.reduce(0.0) { $0 + ($1.rules.groupWeight ?? 100) }
                var weight = 0.0
                for entry in group {
                    weight += entry.rules.groupWeight ?? 100
                    if roll <= weight { winner = entry; break }
                }
            }
            if let winner { for entry in group where entry.id != winner.id { remove(entry) } }
        }
    }
}
