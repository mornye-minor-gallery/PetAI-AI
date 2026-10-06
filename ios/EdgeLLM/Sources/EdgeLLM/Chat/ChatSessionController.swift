import Foundation

// Request state stays on one actor while extensions group model, tool, and
// memory operations without introducing another owner for activeRequestId.
public actor ChatSessionController {
    var isCommittingTurn = false
    var pendingTurnDecision: PendingTurnDecision?
    public static let routedPersonaDefaultsKey =
        "PetAIRoutedPersonaEnabled"

    enum State {
        case modelRequired
        case loading
        case ready
        case generating
        case failed
    }

    let slmConfiguration: SLMConfiguration
    let dialoguePromptPolicy: DialoguePromptPolicy
    let runtime: any ChatInferenceRuntime
    let nativeToolAdapterHub: any ChatPlatformTools
    let nativeToolCoordinator: NativeToolProposalCoordinator
    let platform: any ChatPlatformServices
    let memoryService: any ChatMemoryService
    let toolRouterArtifacts: NativeToolRouterArtifactRegistry?
    let eventSink: @Sendable (NativeChatEvent) -> Void
    let memoryCommitGuard = MemoryTaggedChatCommitGuard()
    var memoryScope: MemoryScope {
        MemoryScope(userID: "local-user", characterID: dialogueContent?.id ?? "default-character")
    }
    let memorySessionID = UUID().uuidString.lowercased()
    let logger: ChatLogger
    let diagnostics: ChatDiagnostics?

    var state = State.modelRequired
    var activeRequestId: String?
    var requiredAsset: NativeAssetKind?
    var forcedAssetSelections: [NativeAssetKind] = []
    var maintenanceRequestID: String?
    var maintenanceTask: Task<Void, Never>?
    var dataExportInProgress = false
    var exportTask: Task<Void, Never>?
    var diaryTask: Task<Void, Never>?
    var dialogueTasks: [UUID: Task<Void, Never>] = [:]
    var cancelRequested = false
    var dialogueContent: DialogueContent?
    var dialogueRetrieval: DialogueRetrievalResources?
    var routedPersonaPrompts: RoutedPersonaPromptSet?
    var embeddingSceneRouter: EmbeddingSceneRouter?
    var nativeToolRouter: (any NativeToolRouting)?
    var routedPersonaSession: RoutedPersonaSessionContext
    var recentTurnStore: DialogueSessionFileStore?
    var recentTurnsLoaded = false
    var captionSource: (id: String, user: String, assistant: String)?
    var captionTask: Task<Void, Never>?
    var captionGeneration: UUID?

    public init(configuration: SLMConfiguration = .production,
                runtime: any ChatInferenceRuntime, memory: any ChatMemoryService,
                platform: any ChatPlatformServices,
                eventSink: @escaping @Sendable (NativeChatEvent) -> Void,
                log: @escaping @Sendable (String) -> Void = { _ in },
                diagnostics: ChatDiagnostics? = nil,
                toolRouterArtifacts: NativeToolRouterArtifactRegistry? = nil) {
        slmConfiguration = configuration
        dialoguePromptPolicy = DialoguePromptPolicy(memoryByteBudget: configuration.memory.promptByteBudget)
        self.runtime = runtime
        self.memoryService = memory
        self.toolRouterArtifacts = toolRouterArtifacts
        self.platform = platform
        self.eventSink = eventSink
        logger = ChatLogger(write: log)
        self.diagnostics = diagnostics
        let tools = CommonChatPlatformTools(platform: platform.tools)
        nativeToolAdapterHub = tools
        routedPersonaSession = RoutedPersonaSessionContext(maximumTurnCount: configuration.persona.recentTurnLimit)
        nativeToolCoordinator = NativeToolProposalCoordinator { try await tools.execute($0) }
    }

    var preparationTask: Task<Void, Never>?
    var isUnloading = false

    public func send(json: String) async {
        guard maintenanceRequestID == nil, !dataExportInProgress, diaryTask == nil, !isUnloading else {
            let id = (try? JSONDecoder().decode(NativeSendRequest.self, from: Data(json.utf8)))?.requestId
            emitError(code: "runtime_busy", message: "데이터 정리 또는 이전 대화가 진행 중입니다.", requestId: id)
            return
        }
        let id = UUID()
        let task = Task { await self.performSend(json: json) }
        dialogueTasks[id] = task
        await task.value
        dialogueTasks.removeValue(forKey: id)
    }

    private func performSend(json: String) async {
        await cancelMemory()
        captionSource = nil
        guard
            let data = json.data(using: .utf8),
            let request = try? JSONDecoder().decode(
                NativeSendRequest.self,
                from: data
            )
        else {
            emitError(
                code: "invalid_request",
                message: UnityBridgeError.invalidRequest.localizedDescription
            )
            return
        }

        let prompt = request.prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !request.requestId.isEmpty, !prompt.isEmpty else {
            emitError(
                code: "invalid_request",
                message: UnityBridgeError.invalidRequest.localizedDescription,
                requestId: request.requestId
            )
            return
        }
        guard state == .ready else {
            if state == .modelRequired {
                let asset = requiredAsset ?? .languageModel
                emit(
                    type: "model_required",
                    requestId: request.requestId,
                    code: asset.requiredCode,
                    message: asset.requiredMessage
                )
            } else {
                emitError(
                    code: "runtime_not_ready",
                    message: "The native chat runtime is not ready.",
                    requestId: request.requestId
                )
            }
            return
        }

        let selectedContent: DialogueContent
        do {
            guard let content = dialogueContent else { throw DialogueContent.SelectionError.characterNotConfigured }
            try content.validateSelection(characterID: request.userProfileContext?.characterId)
            selectedContent = content
        } catch {
            emitError(code: "character_not_configured", message: "선택한 캐릭터의 대화 설정이 없습니다.", requestId: request.requestId)
            return
        }

        let dialogueSnapshot: DialogueSessionSnapshot
        do {
            guard let recentTurnStore else { throw RecentTurnStorageError.notLoaded }
            dialogueSnapshot = try recentTurnStore.beginRequest(in: &routedPersonaSession,
                requestID: request.requestId, userMessage: prompt)
        } catch let error as DialogueSessionError {
            logger.error("Could not begin chat turn: \(String(describing: error))")
            emitError(code: "chat_turn_state_failed", message: "대화 상태를 시작하지 못했습니다. 다시 시도해 주세요.", requestId: request.requestId)
            return
        } catch {
            logger.error("Could not persist chat turn: \(error.localizedDescription)")
            emitError(code: "chat_turn_storage_failed", message: "대화를 저장하지 못해 요청을 시작하지 않았습니다. 저장 공간을 확인하고 다시 시도해 주세요.", requestId: request.requestId)
            return
        }
        state = .generating
        activeRequestId = request.requestId
        cancelRequested = false
        let recentTurnIDs = Set(routedPersonaSession.chatTurns.map(\.requestID))
        emit(type: "generating", requestId: request.requestId)

        let accessPolicy = NativeToolAccessPolicy(
            request.userProfileContext?.toolAccess ?? []
        )
        let baseProfileContext = UserProfileContext(
            userName: request.userProfileContext?.userName,
            characterName: selectedContent.name,
            rhythmGamePlayCount: request.userProfileContext?
                .rhythmGamePlayCount ?? 0,
            rhythmGameBestScore: (
                request.userProfileContext?.rhythmGamePlayCount ?? 0
            ) > 0 ? request.userProfileContext?.rhythmGameBestScore : nil,
            unlockedFeatures: accessPolicy.unlockedSources
        )
        if await handleNativeToolIfNeeded(
            requestID: request.requestId,
            userMessage: prompt,
            accessPolicy: accessPolicy
        ) {
            return
        }

        let userProfileContext = await nativeToolAdapterHub.enrich(
            baseProfileContext,
            allowedTools: accessPolicy.allowedTools
        )

        let recalledMemories = await recallMemories(
            userMessage: prompt,
            excludingTurnIDs: recentTurnIDs
        )
        guard activeRequestId == request.requestId, !cancelRequested else {
            await finishCancelledRequest(request.requestId)
            return
        }
        let generationPrompt: String
        let worldInfoTransaction: WorldInfoTransaction?
        do {
            let prepared = try await prepareRoutedPersonaGeneration(
                requestID: request.requestId,
                userMessage: prompt,
                recalledMemories: recalledMemories,
                userProfileContext: userProfileContext,
                thinkingEnabled: request.thinkingEnabled ?? slmConfiguration.generation.responseThinkingDefault,
                session: dialogueSnapshot, worldContext: try request.worldInfoContext?.context() ?? .init()
            )
            generationPrompt = prepared.prompt
            worldInfoTransaction = prepared.worldInfo
        } catch RuntimeError.generationCancelled {
            await finishCancelledRequest(request.requestId)
            return
        } catch {
            logger.error("Dialogue preparation failed: \(error.localizedDescription)")
            await finishFailedRequest(request.requestId,
                code: "persona_routing_failed",
                message: "대화 구성을 준비하지 못했습니다. 다시 시도해 주세요.")
            return
        }
        guard
            activeRequestId == request.requestId,
            !cancelRequested
        else {
            await finishCancelledRequest(request.requestId)
            return
        }

        do {
            let outcome = try await MemoryTaggedChatProcessor.run(
                configuration: dialoguePromptPolicy.persona,
                primaryStream: {
                    try await self.runtime.generateStream(
                        prompt: generationPrompt,
                        thinkingEnabled: request.thinkingEnabled
                            ?? self.slmConfiguration.generation
                                .responseThinkingDefault
                    )
                },
                retryStream: {
                    try await self.runtime.generateStream(
                        prompt: MemoryTaggedChatPrompt.answerOnlyRetry,
                        thinkingEnabled: request.thinkingEnabled
                            ?? self.slmConfiguration.generation
                                .responseThinkingDefault
                    )
                },
                receiveVisibleText: { text in
                    self.emitVisibleAnswer(text, requestID: request.requestId)
                }
            )

            await diagnostics?.generated(request.requestId, outcome.retryAttempted)
            guard
                activeRequestId == request.requestId,
                !cancelRequested
            else {
                await finishCancelledRequest(request.requestId)
                return
            }

            if outcome.retryAttempted {
                logger.notice(
                    "Tagged chat response required one answer-only retry syntax=\(outcome.primary.syntax.rawValue) succeeded=\(outcome.retrySucceeded)"
                )
            }

            guard outcome.hasVisibleResponse else {
                await finishFailedRequest(request.requestId,
                    code: "response_body_missing",
                    message: "Gemma가 대화 답변을 생성하지 못했습니다. 다시 시도해 주세요.")
                return
            }

            guard try await finishCompletedRequest(request.requestId, visibleText: outcome.visibleText,
                worldInfo: worldInfoTransaction, captionUserMessage: prompt,
                presentation: .dialogue(visibleText: outcome.visibleText), checkpointDialogue: true) else { return }
            if let decision = await memoryCommitGuard.claim(
                requestID: request.requestId,
                outcome: outcome
            ) {
                await remember(
                    userMessage: prompt,
                    sourceMessageID: request.requestId,
                    label: decision
                )
            } else {
                logger.debug(
                    "Memory write skipped; decision was N, unresolved, or already claimed syntax=\(outcome.primary.syntax.rawValue)"
                )
            }
        } catch RuntimeError.generationCancelled {
            await finishCancelledRequest(request.requestId)
        } catch {
            await finishFailedRequest(request.requestId,
                code: "generation_failed",
                message: error.localizedDescription,
                recoverable: false)
        }
    }

    public func cancel(requestID: String? = nil) async {
        guard state == .generating, !isCommittingTurn,
              let activeID = activeRequestId,
              requestID == nil || requestID == activeID else { return }
        cancelRequested = true
        await nativeToolAdapterHub.cancelConfirmation()
        guard activeRequestId == activeID, !isCommittingTurn else { return }
        await runtime.cancel()
    }

    public func unload() async {
        guard !isUnloading, maintenanceRequestID == nil, !dataExportInProgress, diaryTask == nil else { return }
        isUnloading = true
        abandonPendingTurnDecision()
        defer { isUnloading = false }
        if let task = preparationTask { await task.value }
        await cancel()
        // A visible completion can precede its memory write. Keep stores alive
        // until every admitted request has finished its terminal persistence.
        let pendingDialogues = Array(dialogueTasks.values)
        for task in pendingDialogues { await task.value }
        await cancelMemory()
        captionSource = nil
        do {
            try await runtime.unload()
            await memoryService.close()
            routedPersonaPrompts = nil
            embeddingSceneRouter = nil
            nativeToolRouter = nil
            routedPersonaSession.removeAll()
            recentTurnsLoaded = false
            recentTurnStore = nil
            activeRequestId = nil
            cancelRequested = false
            state = .modelRequired
            emit(type: "model_required")
        } catch {
            state = .failed
            emitError(
                code: "unload_failed",
                message: error.localizedDescription
            )
        }
    }

}
