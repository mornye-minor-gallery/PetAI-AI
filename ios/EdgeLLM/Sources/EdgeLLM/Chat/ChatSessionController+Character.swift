import Foundation

extension ChatSessionController {
    /// Changes the conversation owner without unloading the language or embedding models.
    public func activateCharacter(_ characterID: String) async {
        guard !isUnloading, maintenanceRequestID == nil, !dataExportInProgress,
              diaryTask == nil, preparationTask == nil, captionTask == nil,
              characterActivationTask == nil,
              dialogueTasks.isEmpty, activeRequestId == nil, pendingTurnDecision == nil,
              !isCommittingTurn, state != .loading, state != .admitting,
              state != .generating, state != .compacting else {
            emitError(code: "runtime_busy", message: RuntimeError.runtimeBusy.localizedDescription)
            return
        }
        do {
            _ = try DialogueCharacterID(characterID)
            if characterID == selectedCharacterID {
                guard restoreRecentTurnsIfNeeded() else { return }
                emitState()
                return
            }

            // Validate and read the destination before touching the active session.
            let resources = try platform.loadContent(characterID: characterID)
            try resources.content.validateSelection(characterID: characterID)
            let store = try platform.recentTurnStore(characterID: characterID)
            let session = try store.load(maximumTurnCount: slmConfiguration.persona.recentTurnLimit)
                ?? RoutedPersonaSessionContext(maximumTurnCount: slmConfiguration.persona.recentTurnLimit)

            state = .loading
            emit(type: "loading")
            let task = Task {
                await finishCharacterActivation(characterID: characterID, resources: resources,
                    store: store, session: session)
            }
            characterActivationTask = task
            await task.value
            characterActivationTask = nil
        } catch {
            logger.error("Character activation failed id=\(characterID) error=\(error.localizedDescription)")
            emitError(code: "character_not_configured", message: "선택한 캐릭터의 대화 설정이나 기록을 읽지 못했어요.")
        }
    }

    private func finishCharacterActivation(characterID: String, resources: ChatContentResources,
                                           store: DialogueSessionFileStore,
                                           session: RoutedPersonaSessionContext) async {
        let previousID = selectedCharacterID
        let previousContent = dialogueContent
        let previousRetrieval = dialogueRetrieval
        let previousPrompts = routedPersonaPrompts
        let previousSession = routedPersonaSession
        let previousStore = recentTurnStore
        let previousLoaded = recentTurnsLoaded
        let previousTemplate = lastDialogueTemplate
        let previousThinking = lastDialogueThinking
        do {
            selectedCharacterID = characterID
            dialogueContent = resources.content
            dialogueRetrieval = platform.personaEnabled ? resources.retrieval : nil
            routedPersonaPrompts = platform.personaEnabled ? resources.content.promptSet : nil
            routedPersonaSession = session
            recentTurnStore = store
            recentTurnsLoaded = true
            lastDialogueTemplate = nil
            captionSource = nil

            if let dialogueModelIdentifier {
                if session.summary != nil &&
                    (!slmConfiguration.dialogueBudget.contextPolicy.summaryEnabled ||
                     session.summaryModelIdentifier != dialogueModelIdentifier) {
                    try store.compact(in: &routedPersonaSession,
                        retaining: session.contextEntries, summary: nil, modelIdentifier: nil)
                }
                try await runtime.startConversation(configuration: chatConfiguration(
                    systemPrompt: routedPersonaPrompts?
                        .responseSystemPrompt(activeCard: nil,
                            userProfileContext: .init(characterName: resources.content.name))
                        ?? MemoryTaggedChatPrompt.wrappedAxesV1,
                    sampling: routedPersonaPrompts == nil
                        ? slmConfiguration.generation.deterministicSampling
                        : slmConfiguration.generation.responseSampling
                ))
                let (prompts, policy) = configuredDialogue()
                let prepared = try await runtime.prepareDialogue(input: .init(persona: prompts,
                    profile: .init(characterName: resources.content.name), currentMessage: "",
                    exampleDialogue: platform.personaEnabled ? resources.content.exampleDialogue : ""),
                    policy: policy, thinkingEnabled: slmConfiguration.generation.responseThinkingDefault)
                lastDialogueTemplate = prepared.contextTemplate
                lastDialogueThinking = slmConfiguration.generation.responseThinkingDefault
                state = .ready
            } else {
                state = .modelRequired
            }
            emit(type: "history_restored",
                recentEntries: routedPersonaSession.recentEntries.map(NativeRestoredDialogueEntry.init))
            emitState()
        } catch {
            selectedCharacterID = previousID
            dialogueContent = previousContent
            dialogueRetrieval = previousRetrieval
            routedPersonaPrompts = previousPrompts
            routedPersonaSession = previousSession
            recentTurnStore = previousStore
            recentTurnsLoaded = previousLoaded
            lastDialogueTemplate = previousTemplate
            lastDialogueThinking = previousThinking
            state = .failed
            logger.error("Character activation failed id=\(characterID) error=\(error.localizedDescription)")
            emitError(code: "character_activation_failed", message: "캐릭터 대화를 준비하지 못했어요. 다시 시도해 주세요.")
        }
    }
}
