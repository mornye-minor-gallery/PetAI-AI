import Foundation

/// Selection is a transaction: callers commit nextState only with a successful reply.
/// Source order follows SillyTavern 06bde939 checkWorldInfo; browser hooks are host inputs.
public enum WorldInfoEngine {
    public static func validate(_ settings: WorldInfoSettings) throws {
        guard settings.tokenBudget > 0 else { throw WorldInfoError.invalidBudget }
        guard (0...1000).contains(settings.scanDepth) else { throw WorldInfoError.invalidScanDepth }
        if let p = settings.rules.budgetPercent, !p.isFinite || p <= 0 || p > 100 { throw WorldInfoError.invalidBudget }
        for n in [settings.rules.maximumSteps, settings.rules.minimumActivations, settings.rules.maximumDepth, settings.rules.budgetCap].compactMap({ $0 }) {
            guard n >= 0, n <= 1_000_000 else { throw WorldInfoError.invalidRule("scan") }
        }
        var ids = Set<String>()
        for entry in settings.entries {
            guard !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorldInfoError.invalidID }
            guard ids.insert(entry.id).inserted else { throw WorldInfoError.duplicateID(entry.id) }
            guard (0...1000).contains(entry.scanDepth ?? settings.scanDepth) else { throw WorldInfoError.invalidScanDepth }
            for key in entry.keys + entry.secondaryKeys where key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw WorldInfoError.emptyKey(entry.id) }
            for n in [entry.rules.sticky, entry.rules.cooldown, entry.rules.delay, entry.rules.depth, entry.rules.delayUntilRecursion].compactMap({ $0 }) {
                guard n >= 0, n <= 1_000_000 else { throw WorldInfoError.invalidRule(entry.id) }
            }
            if let p = entry.rules.probability, !p.isFinite || !(0...100).contains(p) { throw WorldInfoError.invalidRule(entry.id) }
            if let w = entry.rules.groupWeight, !w.isFinite || w < 0 || w > 1_000_000 { throw WorldInfoError.invalidRule(entry.id) }
            if let depth = entry.rules.depth, depth > 10_000 { throw WorldInfoError.invalidRule(entry.id) }
            let fields = Set(["personaDescription", "characterDescription", "characterPersonality", "characterDepthPrompt", "scenario", "creatorNotes"])
            if let requested = entry.rules.scanFields, !Set(requested).isSubset(of: fields) { throw WorldInfoError.invalidRule(entry.id) }
            if entry.position == .outlet, entry.rules.outlet?.isEmpty != false { throw WorldInfoError.invalidRule(entry.id) }
        }
    }

    public static func select(settings: WorldInfoSettings, messages: [String], note: AuthorsNoteResolution?,
                              measurer: any DialogueTokenMeasuring, context: WorldInfoContext = .init(),
                              state: WorldInfoState = .init(), textContext: WorldInfoTextContext = .init()) async throws -> WorldInfoSelection {
        try validate(settings)
        guard context.contextTokens > 0, context.contextTokens <= Int(Int32.max) else { throw WorldInfoError.invalidBudget }
        var budget = settings.tokenBudget
        if let percent = settings.rules.budgetPercent { budget = max(1, Int((Double(context.contextTokens) * percent / 100).rounded())) }
        if let cap = settings.rules.budgetCap, cap > 0 { budget = min(budget, cap) }
        let direct = settings.entries.enumerated().sorted {
            $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order > $1.element.order
        }.map(\.element)
        // Scoped order is already decided by the library; re-sorting it would erase
        // chat/persona and character-first priority before budget selection.
        let scoped = try settings.library?.entries(character: context.characterName) ?? []
        let sorted = scoped + direct
        try validate(.init(tokenBudget: settings.tokenBudget, entries: sorted, scanDepth: settings.scanDepth, rules: settings.rules))
        let temporalEntries = try sorted.map(temporalEntry)
        let temporal = try WorldInfoTemporalRules.prepare(state: state, entries: temporalEntries, messageNumber: context.messageNumber)
        var random = WorldInfoRandom(state: context.randomSeed)
        var macros = textContext
        var selected: [WorldInfoEntry] = [], traces: [WorldInfoEntryTrace] = []
        var failedProbability = Set<String>()
        var overflowed = false, maxScanned = 0, didScanNote = false
        var recursion: [String] = [], activatedText = ""
        var depth = settings.scanDepth, scanState = 1, step = 0
        var levels = Array(Set(sorted.compactMap { $0.rules.delayUntilRecursion }.filter { $0 > 0 })).sorted()
        var recursionLevel = levels.isEmpty ? 0 : levels.removeFirst()
        while scanState != 0 {
            try Task.checkCancellation()
            if let limit = settings.rules.maximumSteps, limit > 0, step >= limit { break }
            step += 1
            var candidates: [WorldInfoEntry] = []
            var scores: [String: Int] = [:]
            for var entry in sorted where !selected.contains(where: { $0.id == entry.id }) && !failedProbability.contains(entry.id) {
                let actualDepth = entry.scanDepth ?? depth
                let sticky = temporal.activeSticky.contains(entry.id)
                var primary: String?, secondary: [String] = []
                var reason: WorldInfoEntryTrace.Reason = .selected
                if !entry.enabled { reason = .disabled }
                else if !allowed(entry, context: context) { reason = .filtered }
                else if temporal.delayed.contains(entry.id) { reason = .delayed }
                else if temporal.activeCooldown.contains(entry.id) && !sticky { reason = .cooldown }
                else if !sticky && (entry.rules.delayUntilRecursion ?? 0) > 0 && (scanState != 2 || (entry.rules.delayUntilRecursion ?? 0) > recursionLevel) { reason = .recursionExcluded }
                else if scanState == 2 && settings.rules.recursive == true && entry.rules.excludeRecursion == true && !sticky { reason = .recursionExcluded }
                else {
                    let decorated = decorators(entry.content)
                    entry.content = decorated.text
                    if decorated.force == false { reason = .filtered }
                    else if decorated.force != true && !entry.constant && !sticky && !context.externallyActivated.contains(entry.id) && !((entry.rules.vectorized == true || settings.rules.vector?.enabledForAll == true) && context.vectorMatches.contains(entry.id)) {
                        let buffer = scanBuffer(entry, messages: messages, depth: actualDepth, recursion: scanState == 3 ? [] : recursion, note: note, context: context)
                        maxScanned = max(maxScanned, min(actualDepth, messages.count))
                        if actualDepth > 0 && note?.active == true && note?.allowWorldInfoScan == true && note?.text.isEmpty == false { didScanNote = true }
                        for key in entry.keys {
                            let expanded = try expand(key, macros: &macros, random: &random).trimmingCharacters(in: .whitespacesAndNewlines)
                            if try !expanded.isEmpty && matches(buffer, key: expanded, entry: entry, settings: settings) { primary = key; break }
                        }
                        if primary == nil { reason = .noPrimaryMatch }
                        else {
                            for key in entry.secondaryKeys {
                                let expanded = try expand(key, macros: &macros, random: &random).trimmingCharacters(in: .whitespacesAndNewlines)
                                let match = try !expanded.isEmpty && matches(buffer, key: expanded, entry: entry, settings: settings)
                                if match { secondary.append(key) }
                                // Macro effects follow the original's short circuit evaluation.
                                if (entry.secondaryLogic == .andAny && match) || (entry.secondaryLogic == .notAll && !match) { break }
                            }
                            if !secondarySatisfied(entry, matches: secondary.count) { reason = .secondaryMismatch }
                        }
                    }
                }
                traces.append(.init(id: entry.id, position: entry.position, order: entry.order, scanDepth: actualDepth,
                    constant: entry.constant, primaryMatch: primary, secondaryMatches: secondary, reason: reason,
                    candidateTokens: nil, ignoreBudget: entry.ignoreBudget, delivery: nil))
                if reason == .selected {
                    candidates.append(entry)
                    let buffer = scanBuffer(entry, messages: messages, depth: actualDepth, recursion: scanState == 3 ? [] : recursion, note: note, context: context)
                    scores[entry.id] = try score(entry, buffer: buffer, settings: settings)
                }
            }
            candidates = candidates.enumerated().sorted {
                let a = temporal.activeSticky.contains($0.element.id), b = temporal.activeSticky.contains($1.element.id)
                return a == b ? $0.offset < $1.offset : a
            }.map(\.element)
            let beforeGroups = candidates
            filterGroups(&candidates, selected: selected, scores: scores, settings: settings, temporal: temporal, random: &random)
            for entry in beforeGroups where !candidates.contains(where: { $0.id == entry.id }) { updateTrace(&traces, entry: entry, reason: .groupExcluded) }
            var newContent = ""
            let previousTokens = try await measuredCount(activatedText, measurer)
            for index in candidates.indices {
                var entry = candidates[index]
                if overflowed && !entry.ignoreBudget { updateTrace(&traces, entry: entry, reason: .budgetStopped); continue }
                if let probability = entry.rules.probability, probability != 100, !temporal.activeSticky.contains(entry.id), random.next() * 100 > probability {
                    failedProbability.insert(entry.id); updateTrace(&traces, entry: entry, reason: .probabilityFailed); continue
                }
                entry.content = try expand(entry.content, macros: &macros, random: &random)
                candidates[index] = entry
                newContent += entry.content + "\n"
                var count: Int?
                if !entry.ignoreBudget {
                    let sum = try await measuredCount(newContent, measurer).addingReportingOverflow(previousTokens)
                    guard !sum.overflow else { throw DialogueTokenBudgetError.invalidMeasurement }
                    count = sum.partialValue
                }
                if let count, count >= budget { overflowed = true; updateTrace(&traces, entry: entry, reason: .budgetExceeded, tokens: count) }
                else { selected.append(entry); updateTrace(&traces, entry: entry, reason: .selected, tokens: count) }
            }
            let successful = candidates.filter { !failedProbability.contains($0.id) && $0.rules.preventRecursion != true }
            var next = 0
            if settings.rules.recursive == true && !overflowed && (!successful.isEmpty || (scanState == 3 && !recursion.isEmpty)) { next = 2 }
            if next == 0 && !overflowed && selected.count < (settings.rules.minimumActivations ?? 0) {
                let maxDepth = settings.rules.maximumDepth ?? 0
                if !(maxDepth > 0 && depth > maxDepth) && depth <= messages.count && depth < 1000 { depth += 1; next = 3 }
            }
            if next == 0 && !levels.isEmpty { next = 2; recursionLevel = levels.removeFirst() }
            if next != 0 {
                let text = successful.map(\.content).joined(separator: "\n")
                if !text.isEmpty { recursion.append(text); activatedText = text + "\n" + activatedText }
            }
            scanState = next
        }
        let nextState = try WorldInfoTemporalRules.finish(temporal, selected: temporalEntries.filter { e in selected.contains { $0.id == e.id } }, messageNumber: context.messageNumber)
        for index in selected.indices {
            while true {
                do {
                    selected[index].content = try DialogueRegex.apply(selected[index].content, request: .init(placement: 5), context: &macros)
                    break
                } catch WorldInfoTextError.randomSourceExhausted { macros.randomRolls.append(random.next()) }
            }
            for replacement in selected[index].rules.replacements ?? [] {
                while true {
                    do {
                        selected[index].content = try WorldInfoText.replace(selected[index].content,
                            pattern: replacement.pattern, replacement: replacement.replacement, context: &macros)
                        break
                    } catch WorldInfoTextError.randomSourceExhausted {
                        // The text adapter is atomic on exhaustion. Supply exactly the
                        // next random draw and replay without duplicating variable effects.
                        macros.randomRolls.append(random.next())
                    }
                }
            }
        }
        return .init(selected: selected, trace: .init(tokenBudget: budget, overflowed: overflowed, scannedMessages: maxScanned, scannedNote: didScanNote, entries: traces),
                     nextState: nextState, textContext: macros, automationIDs: selected.compactMap(\.rules.automationID).filter { !$0.isEmpty })
    }

    static func expand(_ text: String, macros: inout WorldInfoTextContext, random: inout WorldInfoRandom) throws -> String {
        while true {
            do { return try WorldInfoText.expand(text, context: &macros) }
            catch WorldInfoTextError.randomSourceExhausted {
                // Atomic text evaluation requests random data lazily, preserving draw
                // order relative to group/probability decisions without a guessed quota.
                macros.randomRolls.append(random.next())
            }
        }
    }

    private static func measuredCount(_ text: String, _ measurer: any DialogueTokenMeasuring) async throws -> Int {
        let count = try await measurer.countTokens(text)
        guard count >= 0 else { throw DialogueTokenBudgetError.invalidMeasurement }
        return count
    }
    private static func updateTrace(_ traces: inout [WorldInfoEntryTrace], entry: WorldInfoEntry, reason: WorldInfoEntryTrace.Reason, tokens: Int? = nil) {
        guard let i = traces.lastIndex(where: { $0.id == entry.id }) else { return }
        let t = traces[i]
        traces[i] = .init(id: t.id, position: t.position, order: t.order, scanDepth: t.scanDepth, constant: t.constant, primaryMatch: t.primaryMatch, secondaryMatches: t.secondaryMatches, reason: reason, candidateTokens: tokens, ignoreBudget: t.ignoreBudget, delivery: nil)
    }
}
