import Foundation

public struct DialogueCompactionPlan: Sendable {
    public let retainedEntries: [RecentDialogueEntry]
    public let excludedEntries: [RecentDialogueEntry]
    public let summaryTokenLimit: Int
    public let summaryInput: String
    public let previousSummary: String?
    public var needsSummaryGeneration: Bool { summaryTokenLimit > 0 && !excludedEntries.isEmpty }
    let originalEntries: [RecentDialogueEntry]
}

public struct CompactedDialogueContext: Sendable {
    public let summary: String?
    public let retainedEntries: [RecentDialogueEntry]
    public let modelInput: DialogueModelInput
    public let inputTokens: Int
}

public enum DialogueContextCompactor {
    public static let summaryInstruction = "대화 내용을 짧게 요약해주세요."

    public static func requiresCompaction(template: DialogueContextTemplate, entries: [RecentDialogueEntry],
                                         summary: String?, budget: DialogueTokenBudget,
                                         measurer: any DialogueTokenMeasuring) async throws -> Bool {
        let count = try await measured(template.input(entries: entries, summary: summary), measurer)
        return count > inputCapacity(budget)
    }

    public static func plan(template: DialogueContextTemplate, entries: [RecentDialogueEntry],
                            previousSummary: String?, budget: DialogueTokenBudget,
                            measurer: any DialogueTokenMeasuring) async throws -> DialogueCompactionPlan {
        try budget.validate()
        let capacity = inputCapacity(budget)
        let empty = try await measured(template.input(entries: [], summary: nil), measurer)
        guard empty <= capacity else {
            throw DialogueTokenBudgetError.exceeded(input: empty + questionReservation(budget),
                reservedOutput: budget.outputTokens, capacity: budget.contextTokens)
        }
        var headerCost = 0
        if budget.contextPolicy.summaryEnabled {
            let marker = "요약"
            let markerTokens = try await measurer.countTokens(marker)
            guard markerTokens >= 0 else { throw DialogueTokenBudgetError.invalidMeasurement }
            headerCost = max(0, try await measured(template.input(entries: [], summary: marker), measurer)
                - empty - markerTokens)
        }
        let summaryLimit = budget.contextPolicy.summaryEnabled
            ? min(budget.contextPolicy.summaryTokens, max(0, capacity - empty - headerCost)) : 0
        let reservedSummary = summaryLimit > 0 ? summaryLimit + headerCost : 0
        var retained = recentSuffix(entries, requestLimit: budget.contextPolicy.recentTurns)
        while !retained.isEmpty {
            let count = try await measured(template.input(entries: retained, summary: nil), measurer)
            if count <= capacity - reservedSummary { break }
            retained.removeFirst()
        }
        let excluded = Array(entries.prefix(entries.count - retained.count))
        let source = [previousSummary.map { "## 이전 대화 요약\n" + $0 },
            excluded.isEmpty ? nil : "## 정리할 대화\n" + excluded.flatMap(\.visibleMessages)
                .map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")]
            .compactMap { $0 }.joined(separator: "\n\n")
        return .init(retainedEntries: retained, excludedEntries: excluded, summaryTokenLimit: summaryLimit,
                     summaryInput: source, previousSummary: previousSummary, originalEntries: entries)
    }

    public static func finish(plan: DialogueCompactionPlan, summary: String?, template: DialogueContextTemplate,
                              budget: DialogueTokenBudget, measurer: any DialogueTokenMeasuring) async throws -> CompactedDialogueContext {
        let capacity = inputCapacity(budget)
        var retained = plan.retainedEntries
        var fitted: String?
        if let summary, budget.contextPolicy.summaryEnabled {
            let text = try await DialogueTokenTruncation.prefix(summary.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumTokens: plan.summaryTokenLimit, measurer: measurer)
            fitted = text.isEmpty ? nil : text
        }
        if fitted == nil {
            // This is also the approved generation-failure path. Reuse the slot
            // reserved for a summary to retain as many of the latest three turns as fit.
            retained = recentSuffix(plan.originalEntries, requestLimit: budget.contextPolicy.recentTurns)
            while !retained.isEmpty {
                let count = try await measured(template.input(entries: retained, summary: nil), measurer)
                if count <= capacity { break }
                retained.removeFirst()
            }
        }
        var input = template.input(entries: retained, summary: fitted)
        var count = try await measured(input, measurer)
        // Section counts are not additive. Final native-template measurement is
        // authoritative; any remaining boundary difference is removed from the summary.
        while count > capacity, let text = fitted, !text.isEmpty {
            let tokens = try await measurer.countTokens(text)
            guard tokens >= 0 else { throw DialogueTokenBudgetError.invalidMeasurement }
            let next = try await DialogueTokenTruncation.prefix(text,
                maximumTokens: max(0, tokens - max(1, count - capacity)), measurer: measurer)
            fitted = next.isEmpty ? nil : (next == text ? String(text.dropLast()) : next)
            input = template.input(entries: retained, summary: fitted)
            count = try await measured(input, measurer)
        }
        guard count <= capacity else {
            throw DialogueTokenBudgetError.exceeded(input: count + questionReservation(budget),
                reservedOutput: budget.outputTokens, capacity: budget.contextTokens)
        }
        return .init(summary: fitted, retainedEntries: retained, modelInput: input, inputTokens: count)
    }

    private static func recentSuffix(_ entries: [RecentDialogueEntry], requestLimit: Int) -> [RecentDialogueEntry] {
        guard requestLimit > 0 else { return [] }
        var start = entries.count, requests = 0
        for index in entries.indices.reversed() {
            if case .request = entries[index] {
                guard requests < requestLimit else { break }
                requests += 1
            }
            start = index
        }
        return Array(entries[start...])
    }

    private static func questionReservation(_ budget: DialogueTokenBudget) -> Int { budget.limits?.questionTokens ?? 0 }
    private static func inputCapacity(_ budget: DialogueTokenBudget) -> Int {
        max(0, budget.contextTokens - budget.outputTokens - questionReservation(budget))
    }
    private static func measured(_ input: DialogueModelInput, _ measurer: any DialogueTokenMeasuring) async throws -> Int {
        try Task.checkCancellation()
        let count = try await measurer.measureInput(input)
        guard count >= 0 else { throw DialogueTokenBudgetError.invalidMeasurement }
        return count
    }
}
