import Foundation

extension ChatSessionController {
    public func initialize() async { await prepareOnce(selectingModel: false) }
    public func selectModel() async { await prepareOnce(selectingModel: true) }

    func prepareOnce(selectingModel: Bool) async {
        guard !isUnloading, maintenanceRequestID == nil, !dataExportInProgress,
              diaryTask == nil, characterActivationTask == nil else {
            emitError(code: "runtime_busy", message: RuntimeError.runtimeBusy.localizedDescription)
            return
        }
        if let task = preparationTask {
            await task.value
            guard restoreRecentTurnsIfNeeded() else { return }
            emitState()
            return
        }
        guard state != .generating, state != .admitting, state != .compacting else {
            emitError(code: "runtime_busy", message: RuntimeError.runtimeBusy.localizedDescription)
            return
        }
        guard restoreRecentTurnsIfNeeded() else { return }
        if !selectingModel && state == .ready { emitState(); return }
        let replacingReadyModel = state == .ready
        state = .loading
        // Claim the task before the first suspension. Duplicate callers await the same work.
        let task = Task {
            if selectingModel { await self.performModelSelection(isReplacingReadyLanguageModel: replacingReadyModel) }
            else { await self.performInitialization() }
        }
        preparationTask = task
        emit(type: "loading")
        await task.value
        preparationTask = nil
    }

    func performInitialization() async {
        do {
            await platform.refreshModelAssets()
            if let missingAsset = try await missingAssetKind() {
                requireAsset(missingAsset)
                return
            }

            await prepareSavedRuntime()
        } catch {
            state = .failed
            emitError(
                code: "model_store_failed",
                message: error.localizedDescription
            )
        }
    }

    func performModelSelection(isReplacingReadyLanguageModel: Bool) async {
        if isReplacingReadyLanguageModel {
            forcedAssetSelections = [.languageModel]
            state = .loading
            emit(
                type: "loading",
                message: "새 Gemma 모델 파일을 선택해 주세요."
            )
        }

        var selectingAsset: NativeAssetKind?
        do {
            while true {
                let isForcedSelection = !forcedAssetSelections.isEmpty
                let nextAsset = isForcedSelection
                    ? forcedAssetSelections[0]
                    : try await missingAssetKind()
                guard let nextAsset else {
                    break
                }

                selectingAsset = nextAsset
                // File selection is part of the pending preparation, not its terminal result.
                requiredAsset = nextAsset
                emit(type: "loading", code: nextAsset.requiredCode, message: nextAsset.requiredMessage)
                let selectedURL = try await platform.selectAsset(nextAsset)
                if isReplacingReadyLanguageModel {
                    try await runtime.unload()
                }
                try await importAsset(
                    from: selectedURL,
                    kind: nextAsset
                )
                if isForcedSelection {
                    forcedAssetSelections.removeFirst()
                }
                selectingAsset = nil
            }

            await prepareSavedRuntime()
        } catch UnityBridgeError.modelSelectionCancelled {
            if isReplacingReadyLanguageModel {
                forcedAssetSelections.removeAll()
                requiredAsset = nil
                state = .ready
                emit(type: "ready")
                return
            }
            state = .modelRequired
            requiredAsset = selectingAsset ?? requiredAsset ?? .languageModel
            emit(
                type: "model_required",
                code: "model_selection_cancelled",
                message: "파일 선택을 취소했습니다. 다시 전송하면 설정을 이어갑니다."
            )
        } catch {
            state = .failed
            emitError(
                code: "model_selection_failed",
                message: error.localizedDescription
            )
        }
    }

    func prepareSavedRuntime() async {
        await cancelMemory()
        captionSource = nil
        state = .loading
        requiredAsset = nil
        emit(
            type: "loading",
            message: "Gemma와 EdgeMem을 기기에서 준비하고 있어요."
        )

        let modelURL: URL
        let embeddingModelURL: URL
        let tokenizerURL: URL
        do {
            let assets = try await platform.resolveModelAssets()
            modelURL = assets.languageModelURL
            embeddingModelURL = assets.embeddingModelURL
            tokenizerURL = assets.tokenizerURL
        } catch {
            state = .failed
            emitError(
                code: "model_store_failed",
                message: error.localizedDescription
            )
            return
        }

        // Recovery and model replacement rebuild inference resources, not the conversation.
        // Keep the committed history, World Info state and clock for the next prompt snapshot.
        // Explicit session teardown (unload) and test data reset own dialogue erasure.
        lastDialogueTemplate = nil
        nativeToolRouter = nil
        do {
            routedPersonaPrompts = try loadRoutedPersonaPromptsIfEnabled()
        } catch {
            state = .failed
            emitError(
                code: "persona_content_unavailable",
                message: "캐릭터 대화 설정 파일이 없거나 형식이 올바르지 않습니다."
            )
            logger.error(
                "Routed persona prompt verification failed error=\(error.localizedDescription)"
            )
            return
        }

        do {
            try await runtime.prepare(modelURL: modelURL)
            try await runtime.startConversation(
                configuration: chatConfiguration(
                    systemPrompt: routedPersonaPrompts?
                        .responseSystemPrompt(activeCard: nil, userProfileContext: .init(
                            characterName: dialogueContent?.name ?? UserProfileContext.defaultCharacterName))
                        ?? MemoryTaggedChatPrompt.wrappedAxesV1,
                    sampling: routedPersonaPrompts == nil
                        ? slmConfiguration.generation.deterministicSampling
                        : slmConfiguration.generation.responseSampling
                )
            )
            do {
                // Validate authored fixed text before opening Send. This only
                // renders and tokenizes input; it does not generate a reply.
                let (prompts, policy) = configuredDialogue()
                let prepared = try await runtime.prepareDialogue(input: .init(persona: prompts,
                    profile: .init(characterName: dialogueContent?.name ?? UserProfileContext.defaultCharacterName),
                    currentMessage: "", exampleDialogue: platform.personaEnabled ? dialogueContent?.exampleDialogue ?? "" : ""),
                    policy: policy, thinkingEnabled: slmConfiguration.generation.responseThinkingDefault)
                lastDialogueTemplate = prepared.contextTemplate
                lastDialogueThinking = slmConfiguration.generation.responseThinkingDefault
            }
        } catch let reason as ModelLoadMemoryDeferred {
            // Files and restored history are valid. Keep the model-download path
            // separate so Retry re-observes memory rather than re-importing assets.
            state = .preparationDeferred(reason)
            emitState()
            return
        } catch {
            logger.error("Language model preparation failed: \(error.localizedDescription)")
            if error is DialogueInputLimitError || error is DialogueTokenBudgetError || error is DialogueContextOverflow {
                state = .failed
                emitError(code: "prompt_configuration_invalid", message: "캐릭터 대화 설정이 입력 상한을 넘었어요.")
                return
            }
            forcedAssetSelections = [.languageModel]
            requireAsset(.languageModel)
            return
        }

        do {
            guard let store = recentTurnStore else { throw RecentTurnStorageError.notLoaded }
            if routedPersonaSession.summary != nil &&
                (!slmConfiguration.dialogueBudget.contextPolicy.summaryEnabled
                    || routedPersonaSession.summaryModelIdentifier != modelURL.lastPathComponent) {
                try store.compact(in: &routedPersonaSession, retaining: routedPersonaSession.contextEntries,
                                  summary: nil, modelIdentifier: nil)
                try await runtime.eraseCheckpoint()
            } else if let summary = routedPersonaSession.summary {
                let shortened = try await DialogueTokenTruncation.prefix(summary,
                    maximumTokens: slmConfiguration.dialogueBudget.contextPolicy.summaryTokens, measurer: runtime)
                if shortened != summary {
                    try store.compact(in: &routedPersonaSession, retaining: routedPersonaSession.contextEntries,
                        summary: shortened.isEmpty ? nil : shortened, modelIdentifier: modelURL.lastPathComponent)
                    try await runtime.eraseCheckpoint()
                }
            }
            dialogueModelIdentifier = modelURL.lastPathComponent
        } catch {
            state = .failed
            emitError(code: "chat_turn_storage_failed", message: "대화 문맥을 저장하지 못했어요.")
            return
        }

        do {
            try await memoryService.prepare(
                modelURL: embeddingModelURL,
                tokenizerURL: tokenizerURL
            )
        } catch {
            logger.error("Embedding preparation failed: \(error.localizedDescription)")
            forcedAssetSelections = [.embeddingModel, .tokenizer]
            requireAsset(.embeddingModel)
            return
        }

        do {
            // Learned artifacts are supplied by the host after checking their data rights.
            // A public checkout intentionally has no bundled Tool Router weights.
            if let toolRouterArtifacts {
                let pipeline = try toolRouterArtifacts.load()
                nativeToolRouter = EmbeddingMLPNativeToolRouter(
                    embedder: memoryService,
                    pipeline: pipeline
                )
                logger.notice("Native Tool Router ready artifact=\(pipeline.artifactID)")
            } else {
                nativeToolRouter = nil
                logger.notice("Native Tool Router not configured; supply approved artifacts to enable routing.")
            }
        } catch {
            nativeToolRouter = nil
            logger.error(
                "Native Tool Router unavailable; requests will stay in chat error=\(error.localizedDescription)"
            )
        }

        forcedAssetSelections.removeAll()
        state = .ready
        emit(type: "ready")
    }

    func missingAssetKind() async throws -> NativeAssetKind? {
        try await platform.missingAsset()
    }

    func importAsset(from selectedURL: URL, kind: NativeAssetKind) async throws {
        if kind == .languageModel { try await runtime.eraseCheckpoint() }
        try await platform.importAsset(selectedURL, kind: kind)
    }

    func requireAsset(_ asset: NativeAssetKind) {
        state = .modelRequired
        requiredAsset = asset
        emit(
            type: "model_required",
            code: asset.requiredCode,
            message: asset.requiredMessage
        )
    }

    func loadRoutedPersonaPromptsIfEnabled() throws -> RoutedPersonaPromptSet? {
        diagnostics?.mark("retrieval.load.begin", [:])
        defer { diagnostics?.mark("retrieval.load.exit", [:]) }
        dialogueContent = nil
        dialogueRetrieval = nil
        let resources = try platform.loadContent(characterID: selectedCharacterID)
        dialogueContent = resources.content
        dialogueRetrieval = platform.personaEnabled ? resources.retrieval : nil
        return platform.personaEnabled ? resources.content.promptSet : nil
    }

    func chatConfiguration(
        systemPrompt: String,
        sampling: SLMConfiguration.Sampling
    ) -> ConversationConfiguration {
        ConversationConfiguration(
            systemPrompt: systemPrompt,
            temperature: sampling.temperature,
            topK: sampling.samplerTopK,
            topP: sampling.topP,
            maxOutputTokens: slmConfiguration.dialogueBudget.outputTokens
        )
    }

}
