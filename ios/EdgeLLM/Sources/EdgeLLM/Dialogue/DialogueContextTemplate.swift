import Foundation

/// Keeps already-selected request material, never a copy of the old conversation.
/// Replacing history changes neither the native roles nor the fixed first turn.
public struct DialogueContextTemplate: Sendable {
    struct HistoryBlock: Sendable {
        let depth: Int
        let section: DialoguePromptSection
    }

    private let system: [DialoguePromptSection]
    private let context: [DialoguePromptSection]
    private let memory: String?
    private let before: [DialoguePromptSection]
    private let after: [DialoguePromptSection]
    private let historyBlocks: [HistoryBlock]
    private let topicID: String?

    init(system: [DialoguePromptSection], context: [DialoguePromptSection], memory: String?,
         before: [DialoguePromptSection], after: [DialoguePromptSection], historyBlocks: [HistoryBlock], topicID: String? = nil) {
        self.system = system; self.context = context; self.memory = memory
        self.before = before; self.after = after; self.historyBlocks = historyBlocks
        self.topicID = topicID
    }

    func historySections(_ history: [RoutedPersonaSessionContext.Turn], summary: String?) -> [DialoguePromptSection] {
        var insertions: [Int: [DialoguePromptSection]] = [:]
        for block in historyBlocks {
            insertions[max(0, history.count + 1 - block.depth), default: []].append(block.section)
        }
        var parts: [DialoguePromptSection] = []
        if let summary, !summary.isEmpty {
            parts.append(.init(id: "summary", text: "## 이전 대화 요약\n" + summary))
        }
        return parts + DialoguePromptRenderer.historySections(history, insertions: insertions)
    }

    public func input(history: [RoutedPersonaSessionContext.Turn], summary: String?,
                      currentMessage: String = "") -> DialogueModelInput {
        renderInput(history: history, summary: summary, currentMessage: currentMessage, includeTopic: true)
    }

    func input(entries: [RecentDialogueEntry], summary: String?, currentMessage: String = "") -> DialogueModelInput {
        // Compaction removes support together with its authored speech, including
        // the context used for prefill before the next request is rebuilt.
        renderInput(history: entries.flatMap(\.visibleMessages), summary: summary, currentMessage: currentMessage,
                    includeTopic: topicID == nil || topicID == HomeTopicContext.latest(in: entries)?.id)
    }

    private func renderInput(history: [RoutedPersonaSessionContext.Turn], summary: String?,
                             currentMessage: String, includeTopic: Bool) -> DialogueModelInput {
        let groups: [(DialoguePromptRole, [DialoguePromptSection])] = [
            (.system, system), (.user, historySections(history, summary: summary)),
            (.system, includeTopic ? context : context.filter { $0.id != "topic" })
        ]
        let messages = groups.compactMap { role, parts -> DialoguePromptMessage? in
            guard !parts.isEmpty else { return nil }
            return .init(role: role, text: parts.map(\.text).joined(separator: "\n\n"))
        }
        let current = DialoguePromptRenderer.userSections(memorySection: memory, currentMessage: currentMessage,
            beforeCurrent: before, afterCurrent: after).map(\.text).joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(initialMessages: messages, currentUserMessage: "## 현재 사용자 입력과 회수 기억\n" + current)
    }
}
