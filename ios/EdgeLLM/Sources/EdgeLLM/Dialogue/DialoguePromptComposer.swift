import Foundation

/// Shared by the live app and evaluation. Receives values, never performs retrieval or inference.
public enum DialoguePromptComposer {
    public static func prepare(input: DialoguePromptInput,
                               policy: DialoguePromptPolicy = .production) throws -> PreparedDialogue {
        guard input.worldInfo == nil else { throw WorldInfoError.tokenMeasurerRequired }
        guard policy.memoryByteBudget > 0 else { throw DialoguePromptError.invalidMemoryByteBudget }
        let memory = DialogueMemoryContext.prepare(input.memories, byteBudget: policy.memoryByteBudget)
        return try assemble(input: input, policy: policy, memory: memory, memoryByteBudget: policy.memoryByteBudget, note: resolveNote(input))
    }

    static func insertionLayout(input: DialoguePromptInput, policy: DialoguePromptPolicy, note: AuthorsNoteResolution? = nil, worldInsertions: [DialoguePromptInsertion] = []) throws -> DialogueInsertionLayout {
        guard policy.nameRulePlacement == .system || policy.persona.enforceCharacterName else {
            throw DialoguePromptError.inactiveNameRulePlacement
        }
        if let session = input.session, session.history != input.history {
            throw DialoguePromptError.sessionHistoryMismatch
        }
        let nameRule: DialoguePromptInsertion? = policy.nameRulePlacement == .system ? nil : .init(
            id: "nameRule", source: .nameRule, text: policy.persona.nameInstruction(characterName: input.profile.characterName),
            placement: policy.nameRulePlacement == .beforeCurrent ? .beforeCurrent : .afterCurrent)
        return try DialogueInsertionLayout(input.insertions + worldInsertions + (note?.insertion.map { [$0] } ?? []), nameRule: nameRule, historyCount: input.history.count)
    }

    static func resolveNote(_ input: DialoguePromptInput) throws -> AuthorsNoteResolution? {
        // Upstream always registers an empty default note: WI can fill AN-top/bottom
        // even without user-authored note text. With no WI, preserve the existing nil path.
        guard let settings = input.authorsNote ?? (input.worldInfo == nil ? nil : AuthorsNoteSettings()) else { return nil }
        guard let snapshot = input.session else { throw DialoguePromptError.missingSessionSnapshot }
        return try AuthorsNoteResolver.resolve(settings, userMessageNumber: snapshot.currentUserMessageNumber)
    }

    static func assemble(input: DialoguePromptInput, policy: DialoguePromptPolicy,
                         memory: DialogueMemoryContext, memoryByteBudget: Int?, note: AuthorsNoteResolution?,
                         worldInfo: WorldInfoPromptProjection? = nil, authoredContext: WorldInfoTextContext? = nil) throws -> PreparedDialogue {
        var macroContext = worldInfo?.selection.textContext ?? authoredContext ?? authoredTextContext(input)
        macroContext.outlets = worldInfo?.outlets ?? [:]
        var random = WorldInfoRandom(state: DialogueSeedPolicy.worldInfo(base: input.worldInfoContext.randomSeed, completedMessages: input.session?.completedMessages ?? 0))
        func authored(_ text: String) throws -> String {
            guard text.contains("{{") || text.contains("<") else { return text }
            return try WorldInfoEngine.expand(text, macros: &macroContext, random: &random)
        }
        let expandedBaseNote = try note.map { $0.replacingText(try authored($0.text)) }
        // Selected bodies have already run their macro effects in the engine. Only
        // expand the authored note itself, then join it with those prepared bodies.
        let projection = worldInfo.map { WorldInfoPromptProjection(selection: $0.selection, note: expandedBaseNote) }
        let expandedNote = projection?.note ?? expandedBaseNote
        let layout = try insertionLayout(input: input, policy: policy, note: expandedNote,
            worldInsertions: projection?.insertions ?? [])
        let exampleText = try authored(input.exampleDialogue)
        let instruction = policy.persona.nameInstruction(characterName: input.profile.characterName)
        // Move the rule as an item before serialization. User text is never searched
        // for section markers, so a quoted marker cannot change the layout.
        let positionedParts = DialoguePromptRenderer.userSections(
            memorySection: memory.section,
            currentMessage: input.currentMessage,
            beforeCurrent: layout.before,
            afterCurrent: layout.after)
        let unpositioned = memory.render(currentMessage: input.currentMessage)
        var systemPolicy = policy.persona
        if policy.nameRulePlacement != .system { systemPolicy.enforceCharacterName = false }
        let baseParts = try DialoguePromptRenderer.systemSections(prompts: input.persona, activeCard: input.activeCard,
            userProfileContext: input.profile, configuration: systemPolicy).map { section in
                DialoguePromptSection(id: section.id,
                    text: try (["persona", "scene"].contains(section.id) ? authored(section.text) : section.text),
                    role: section.role, cacheStability: section.cacheStability)
            }
        // Lore anchors retain their relative order inside the request-dynamic tail. The stable
        // persona and output contracts must stay contiguous at the front: native KV reuse stops
        // at the first changed token, so inserting request data between them defeats prefix caching.
        let characterEnd = baseParts.prefix { $0.id == "persona" || $0.id == "scene" }.count
        let exampleParts: [DialoguePromptSection] = exampleText.isEmpty ? [] : [
            .init(id: "dialogue.examples", text: exampleText, role: .system, cacheStability: .sessionStable)
        ]
        let stableParts = baseParts.filter { $0.cacheStability == .sessionStable } + exampleParts
        let dynamicCharacterParts = baseParts.prefix(characterEnd).filter { $0.cacheStability == .requestDynamic }
        let dynamicRemainingParts = baseParts.dropFirst(characterEnd).filter { $0.cacheStability == .requestDynamic }
        let systemParts = stableParts + layout.beforeSystem + layout.beforePersona + dynamicCharacterParts
            + layout.afterPersona + dynamicRemainingParts + layout.afterSystem
        let systemPrompt = systemParts.map(\.text).joined(separator: "\n\n")
        let historyParts = DialoguePromptRenderer.historySections(input.history, insertions: layout.history)
        let currentText = positionedParts.map(\.text).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt = (historyParts.map(\.text) + ["## 현재 사용자 입력과 회수 기억\n" + currentText]).joined(separator: "\n\n")
        // Random rolls are request-local evidence, not session memory. Stable pick
        // choices and explicit variables are the persistent part of macro state.
        macroContext.randomRolls = []; macroContext.randomIndex = 0
        return PreparedDialogue(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            unpositionedUserPrompt: DialoguePromptRenderer.historyInput(history: input.history, currentText: unpositioned),
            memoryAugmentedInput: unpositioned,
            nameInstruction: instruction,
            responseConfiguration: policy.persona,
            trace: .init(systemSections: systemParts.map(\.id),
                         userSections: historyParts.map(\.id) + positionedParts.map(\.id),
                         systemBytes: systemPrompt.utf8.count, userBytes: userPrompt.utf8.count,
                         nameRulePlacement: policy.nameRulePlacement,
                         nameRuleIncluded: policy.persona.enforceCharacterName,
                         historyMessages: input.history.count, memoryByteBudget: memoryByteBudget,
                         memories: memory.trace, insertions: layout.trace, authorsNote: expandedNote, worldInfo: worldInfo?.trace, tokenBudget: nil),
            worldInfoTransaction: .init(state: worldInfo?.selection.nextState ?? input.session?.worldInfoState ?? .init(),
                text: macroContext, automationIDs: worldInfo?.selection.automationIDs ?? [], outlets: worldInfo?.outlets ?? [:]),
            tokenSections: systemParts.map { .init(id: $0.id, text: $0.text, role: .system) }
                + historyParts + positionedParts)
    }
}
