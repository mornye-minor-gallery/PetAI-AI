import Foundation

/// Owns the current wire format, including whitespace and the flattened history.
enum DialoguePromptRenderer {
    static func systemPrompt(
        prompts: RoutedPersonaPromptSet,
        activeCard: String?,
        userProfileContext: UserProfileContext = UserProfileContext(),
        configuration: PersonaResponseConfiguration = .production
    ) -> String {
        systemSections(prompts: prompts, activeCard: activeCard,
            userProfileContext: userProfileContext, configuration: configuration)
            .map(\.text).joined(separator: "\n\n")
    }

    static func systemSections(
        prompts: RoutedPersonaPromptSet, activeCard: String?,
        userProfileContext: UserProfileContext,
        configuration: PersonaResponseConfiguration
    ) -> [DialoguePromptSection] {
        var sections: [DialoguePromptSection] = []
        if configuration.includePersona {
            sections.append(.init(id: "persona", text: render(prompts.core, with: userProfileContext),
                                  cacheStability: .sessionStable))
        }
        if configuration.includePersona, let activeCard,
           !activeCard.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty
        {
            sections.append(.init(id: "scene", text:
                """
                ## 이번 응답의 활성 장면 카드
                \(render(activeCard, with: userProfileContext)) 다른 장면 규칙은 이번 응답에 사용하지 않는다.
                """
            ))
        }
        if configuration.includeSessionContext {
            sections.append(.init(id: "profile", text: userProfileContext.promptSection()))
        }
        if configuration.enforceCharacterName, configuration.nameRuleStyle == .identityStatement {
            sections.append(.init(id: "nameRule", text: configuration.nameInstruction(characterName: userProfileContext.characterName),
                                  cacheStability: .sessionStable))
        }
        if configuration.memoryClassification {
            sections.append(.init(id: "responseContract", text: MemoryTaggedChatPrompt.wrappedAxesV1,
                                  cacheStability: .sessionStable))
        }
        // Keep the response action after the format contract so "first sentence"
        // cannot be mistaken for replacing the memory-classification header.
        if configuration.enforceCharacterName, configuration.nameRuleStyle != .identityStatement {
            sections.append(.init(id: "nameRule", text: configuration.nameInstruction(characterName: userProfileContext.characterName),
                                  cacheStability: .sessionStable))
        }
        return sections
    }

    private static func render(
        _ source: String,
        with context: UserProfileContext
    ) -> String {
        source.replacingOccurrences(of: "{{char}}", with: context.characterName)
    }

    static func userSections(memorySection: String?, currentMessage: String, beforeCurrent: [DialoguePromptSection] = [],
               afterCurrent: [DialoguePromptSection] = []) -> [DialoguePromptSection] {
        var sections: [DialoguePromptSection] = []
        if let section = memorySection { sections.append(.init(id: "memories", text: section)) }
        sections.append(contentsOf: beforeCurrent)
        sections.append(.init(id: "currentMessage", text:
            memorySection == nil ? currentMessage : "[Current user message]\n" + currentMessage))
        sections.append(contentsOf: afterCurrent)
        return sections
    }

    static func historySection(_ history: [RoutedPersonaSessionContext.Turn]) -> DialoguePromptSection? {
        guard !history.isEmpty else { return nil }
        return .init(id: "history", text: "## 최근 대화\n" + history.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n"))
    }

    static func historySections(_ history: [RoutedPersonaSessionContext.Turn],
                                insertions: [Int: [DialoguePromptSection]]) -> [DialoguePromptSection] {
        guard !insertions.isEmpty else { return [historySection(history)].compactMap { $0 } }
        var sections: [DialoguePromptSection] = []
        var pending: [String] = []
        var chunk = 0
        func flush() {
            guard !pending.isEmpty else { return }
            sections.append(.init(id: chunk == 0 ? "history" : "history.\(chunk)",
                text: (chunk == 0 ? "## 최근 대화\n" : "") + pending.joined(separator: "\n")))
            pending.removeAll()
            chunk += 1
        }
        for index in 0...history.count {
            if let injected = insertions[index] { flush(); sections.append(contentsOf: injected) }
            if index < history.count { pending.append("\(history[index].role.rawValue): \(history[index].text)") }
        }
        flush()
        return sections
    }

    static func historyInput(history: [RoutedPersonaSessionContext.Turn], currentText: String) -> String {
        var sections: [String] = []
        if let history = historySection(history) { sections.append(history.text) }
        sections.append("## 현재 사용자 입력과 회수 기억\n" + currentText.trimmingCharacters(in: .whitespacesAndNewlines))
        return sections.joined(separator: "\n\n")
    }
}

enum DialoguePromptCacheStability: Sendable { case sessionStable, requestDynamic }

struct DialoguePromptSection: Sendable {
    let id: String
    let text: String
    var role: DialoguePromptRole = .user
    var cacheStability: DialoguePromptCacheStability = .requestDynamic
}
