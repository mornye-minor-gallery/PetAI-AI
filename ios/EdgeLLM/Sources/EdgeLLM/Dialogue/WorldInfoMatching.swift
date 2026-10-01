import Foundation
#if os(Android)
import Crypto
#else
import CryptoKit
#endif

extension WorldInfoEngine {
    static func secondarySatisfied(_ entry: WorldInfoEntry, matches: Int) -> Bool {
        guard !entry.secondaryKeys.isEmpty else { return true }
        switch entry.secondaryLogic {
        case .andAny: return matches > 0
        case .andAll: return matches == entry.secondaryKeys.count
        case .notAny: return matches == 0
        case .notAll: return matches < entry.secondaryKeys.count
        }
    }

    static func matches(_ source: String, key: String, entry: WorldInfoEntry, settings: WorldInfoSettings) throws -> Bool {
        if let matched = try WorldInfoText.matchesRegex(key, text: source) { return matched }
        let sensitive = entry.caseSensitive ?? settings.caseSensitive
        let text = sensitive ? source : source.lowercased()
        let trimmed = key
        let needle = sensitive ? trimmed : trimmed.lowercased()
        if !(entry.matchWholeWords ?? settings.matchWholeWords) || needle.split(whereSeparator: \.isWhitespace).count > 1 {
            return text.range(of: needle, options: .literal) != nil
        }
        // JavaScript's non-Unicode \W treats Korean letters as non-word characters.
        // Keep that observable rule; do not silently replace it with ICU's Unicode \b.
        let pattern = "(?:^|[^A-Za-z0-9_])(" + NSRegularExpression.escapedPattern(for: needle) + ")(?:$|[^A-Za-z0-9_])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

extension WorldInfoEngine {
    static func allowed(_ entry: WorldInfoEntry, context: WorldInfoContext) -> Bool {
        if let triggers = entry.rules.triggers, !triggers.isEmpty, !triggers.contains(context.trigger) { return false }
        let exclude = entry.rules.excludeCharacters == true
        if let names = entry.rules.characterNames, !names.isEmpty, names.contains(context.characterName) == exclude { return false }
        if let tags = entry.rules.characterTags, !tags.isEmpty, !Set(tags).isDisjoint(with: context.characterTags) == exclude { return false }
        return true
    }
    static func scanBuffer(_ entry: WorldInfoEntry, messages: [String], depth: Int, recursion: [String], note: AuthorsNoteResolution?, context: WorldInfoContext) -> String {
        guard depth > 0 else { return "" }
        var pieces = messages.prefix(min(depth, 1000)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for field in ["personaDescription", "characterDescription", "characterPersonality", "characterDepthPrompt", "scenario", "creatorNotes"] where entry.rules.scanFields?.contains(field) == true { if let text = context.scanFields[field], !text.isEmpty { pieces.append(text) } }
        if let note, note.active && note.allowWorldInfoScan && !note.text.isEmpty { pieces.append(note.text) }
        pieces += recursion
        return "\u{1}" + pieces.joined(separator: "\n\u{1}")
    }
    static func score(_ entry: WorldInfoEntry, buffer: String, settings: WorldInfoSettings) throws -> Int {
        guard !entry.keys.isEmpty else { return 0 }
        let primary = try entry.keys.filter { try matches(buffer, key: $0, entry: entry, settings: settings) }.count
        let secondary = try entry.secondaryKeys.filter { try matches(buffer, key: $0, entry: entry, settings: settings) }.count
        return primary + ((entry.secondaryLogic == .andAny || (entry.secondaryLogic == .andAll && secondary == entry.secondaryKeys.count)) ? secondary : 0)
    }
    static func temporalEntry(_ entry: WorldInfoEntry) throws -> WorldInfoTemporalEntry {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Stable canonical content identity, not Swift's process-randomized Hasher.
        let hash = SHA256.hash(data: try encoder.encode(entry)).map { String(format: "%02x", $0) }.joined()
        return .init(id: entry.id, hash: hash, sticky: entry.rules.sticky ?? 0, cooldown: entry.rules.cooldown ?? 0, delay: entry.rules.delay ?? 0)
    }
    static func decorators(_ content: String) -> (text: String, force: Bool?) {
        guard content.hasPrefix("@@") else { return (content, nil) }
        let lines = content.components(separatedBy: "\n")
        var fallback = false, decorators: [String] = [], text = content
        for (i, raw) in lines.enumerated() {
            guard raw.hasPrefix("@@") else { text = lines[i...].joined(separator: "\n"); break }
            if raw.hasPrefix("@@@") && !fallback { continue }
            let line = raw.hasPrefix("@@@") ? String(raw.dropFirst()) : raw
            if line.hasPrefix("@@activate") || line.hasPrefix("@@dont_activate") { decorators.append(line); fallback = false }
            else { fallback = true }
        }
        // Recognition uses a prefix, activation uses an exact decorator as upstream.
        if decorators.contains("@@activate") { return (text, true) }
        if decorators.contains("@@dont_activate") { return (text, false) }
        return (text, nil)
    }
}
