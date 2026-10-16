import Foundation

extension ChatSessionController {
    /// Summary text is user context, not a model-specific KV buffer. Preserve it
    /// across model changes and re-count using the currently loaded tokenizer.
    func reconcileSummary(modelIdentifier: String) async throws {
        guard let summary = routedPersonaSession.summary else { return }
        guard let store = recentTurnStore else { throw RecentTurnStorageError.notLoaded }
        let policy = slmConfiguration.dialogueBudget.contextPolicy
        let retained = policy.summaryEnabled
            ? try await DialogueTokenTruncation.prefix(summary, maximumTokens: policy.summaryTokens, measurer: runtime)
            : ""
        if retained != summary || routedPersonaSession.summaryModelIdentifier != modelIdentifier {
            try store.compact(in: &routedPersonaSession, retaining: routedPersonaSession.contextEntries,
                summary: retained.isEmpty ? nil : retained,
                modelIdentifier: retained.isEmpty ? nil : modelIdentifier)
            try await runtime.eraseCheckpoint()
        }
    }
}
