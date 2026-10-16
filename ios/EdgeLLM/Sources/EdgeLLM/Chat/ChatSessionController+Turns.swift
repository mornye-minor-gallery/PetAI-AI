import Foundation

enum RecentTurnStorageError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .notLoaded: "Recent chat turn storage has not been loaded."
        }
    }
}

extension ChatSessionController {
    func restoreRecentTurnsIfNeeded() -> Bool {
        if recentTurnsLoaded {
            emit(type: "history_restored", recentEntries: routedPersonaSession.recentEntries.map(NativeRestoredDialogueEntry.init))
            return true
        }
        do {
            let store = try platform.recentTurnStore(characterID: selectedCharacterID)
            let saved = try store.load(maximumTurnCount: slmConfiguration.persona.recentTurnLimit) ?? RoutedPersonaSessionContext(
                maximumTurnCount: slmConfiguration.persona.recentTurnLimit)
            routedPersonaSession = saved
            recentTurnStore = store
            recentTurnsLoaded = true
            emit(type: "history_restored", recentEntries: routedPersonaSession.recentEntries.map(NativeRestoredDialogueEntry.init))
            return true
        } catch {
            logger.error("Could not restore recent chat turns error=\(error.localizedDescription)")
            state = .failed
            emitError(code: "chat_turn_storage_failed", message: "최근 대화 기록을 읽지 못했습니다. 기록을 덮어쓰지 않았습니다.")
            return false
        }
    }

    public func recordHomeLine(json: String) {
        guard let request = try? JSONDecoder().decode(NativeHomeLineRequest.self, from: Data(json.utf8)),
              !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            emit(type: "home_line_failed", code: "invalid_home_line", message: "홈 대사를 읽지 못했습니다.")
            return
        }
        // Recording authored home text needs the store, not a loaded model.
        guard state.permitsHistoryRecording, characterActivationTask == nil,
              recentTurnsLoaded, let recentTurnStore,
              activeRequestId == nil, dialogueTasks.isEmpty, !isCommittingTurn, !dataExportInProgress,
              maintenanceRequestID == nil, !isUnloading else {
            emit(type: "home_line_failed", requestId: request.id,
                 code: "runtime_busy", message: "대화가 끝난 뒤 홈 대사를 다시 눌러 주세요.")
            return
        }
        if let topic = request.topic {
            guard topic.isValid, let content = dialogueContent, topic.characterID == content.id else {
                emit(type: "home_line_failed", requestId: request.id,
                    code: "invalid_topic_character", message: "화두의 캐릭터 설정이 대화 설정과 다릅니다.")
                return
            }
        }
        do {
            try recentTurnStore.recordHomeLine(in: &routedPersonaSession,
                id: request.id, text: request.text, topic: request.topic)
            emit(type: "home_line_recorded", requestId: request.id, text: request.text)
        } catch {
            logger.error("Could not persist home line error=\(error.localizedDescription)")
            emit(type: "home_line_failed", requestId: request.id,
                 code: "chat_turn_storage_failed", message: "홈 대사를 저장하지 못했습니다. 저장 공간을 확인한 뒤 다시 눌러 주세요.")
        }
    }

    /// The native session is the only owner of prompt history. Unity events mirror it for display.
    func emitVisibleAnswer(_ text: String, requestID: String,
                           allowAfterCancel: Bool = false) {
        guard activeRequestId == requestID, (allowAfterCancel || !cancelRequested) else { return }
        do {
            try routedPersonaSession.appendAssistantText(requestID: requestID, text: text)
        } catch {
            logger.error("Could not record streamed chat turn request=\(requestID) error=\(error.localizedDescription)")
            finishTurnStorageFailure(requestID)
            return
        }
        emit(type: "token", requestId: requestID, text: text)
    }

    func finishCancelledRequest(_ requestID: String) async {
        guard activeRequestId == requestID else { return }
        let text = routedPersonaSession.chatTurns.last?.assistantMessage ?? ""
        let decision = await displayDecision(requestID, text: text, cancelled: true)
        commitCancelledRequest(requestID, displayedText: decision?.text ?? "")
    }

    private func commitCancelledRequest(_ requestID: String, displayedText: String) {
        guard activeRequestId == requestID else { return }
        defer { isCommittingTurn = false }
        do {
            guard let recentTurnStore else { throw RecentTurnStorageError.notLoaded }
            try recentTurnStore.finishRequest(in: &routedPersonaSession, requestID: requestID,
                status: .cancelled, assistantMessage: displayedText)
        } catch {
            logger.error("Could not record cancelled chat turn request=\(requestID) error=\(error.localizedDescription)")
            finishTurnStorageFailure(requestID)
            return
        }
        state = .ready
        activeRequestId = nil
        cancelRequested = false
        emit(type: "cancelled", requestId: requestID)
    }

    func finishFailedRequest(_ requestID: String, code: String, message: String,
                             recoverable: Bool = true) async {
        guard activeRequestId == requestID else { return }
        if cancelRequested && recoverable {
            await finishCancelledRequest(requestID)
            return
        }
        do {
            guard let recentTurnStore else { throw RecentTurnStorageError.notLoaded }
            try recentTurnStore.finishRequest(in: &routedPersonaSession, requestID: requestID, status: .failed)
        } catch {
            logger.error("Could not record failed chat turn request=\(requestID) error=\(error.localizedDescription)")
            finishTurnStorageFailure(requestID)
            return
        }
        // Runtime generation errors leave the native engine failed until reinitialization.
        state = recoverable ? .ready : .failed
        activeRequestId = nil
        cancelRequested = false
        emitError(code: code, message: message, requestId: requestID)
    }

    @discardableResult
    func finishCompletedRequest(_ requestID: String, visibleText: String,
                                worldInfo: WorldInfoTransaction? = nil,
                                homeSteps: HomeStepObservation? = nil,
                                captionUserMessage: String? = nil,
                                allowAfterCancel: Bool = false,
                                presentation: ChatReplyPresentation,
                                checkpointDialogue: Bool = false) async throws -> Bool {
        guard activeRequestId == requestID else { return false }
        if cancelRequested && !allowAfterCancel {
            await finishCancelledRequest(requestID)
            return false
        }
        let decision = await displayDecision(requestID, text: visibleText, cancelled: false)
        guard let decision, !decision.cancelled else {
            // Host teardown has no confirmed display text; retain only the user request.
            commitCancelledRequest(requestID, displayedText: decision?.text ?? "")
            return false
        }
        defer { isCommittingTurn = false }
        let result: RoutedPersonaSessionContext.CommitResult
        do {
            guard let recentTurnStore else { throw RecentTurnStorageError.notLoaded }
            result = try recentTurnStore.finishRequest(in: &routedPersonaSession,
                requestID: requestID, status: .completed, assistantMessage: visibleText, worldInfo: worldInfo)
        } catch {
            logger.error("Could not persist completed chat turn request=\(requestID) error=\(error.localizedDescription)")
            finishTurnStorageFailure(requestID)
            return false
        }
        if result == .committed, let ids = worldInfo?.automationIDs, !ids.isEmpty {
            emit(type: "world_info_activated", requestId: requestID, worldInfoAutomation: ids)
        }
        // Commit user-visible history first. Keep request admission closed until
        // KV persistence ends; cancellation after this commit cannot undo the turn.
        if result == .committed && checkpointDialogue {
            do { try await runtime.saveCompletedDialogueCheckpoint() }
            catch {
                // The visible turn is already durable. A failed engine blocks
                // the next request, but must not relabel this turn as failed.
                emit(type: "completed", requestId: requestID, text: visibleText, homeSteps: homeSteps, presentation: presentation)
                failContextPreparation(requestID, error: error)
                return true
            }
        }
        if let captionUserMessage {
            captionSource = (requestID, captionUserMessage, visibleText)
        }
        let compact: Bool
        do {
            if let template = lastDialogueTemplate {
                compact = try await DialogueContextCompactor.requiresCompaction(template: template,
                    entries: routedPersonaSession.contextEntries, summary: routedPersonaSession.summary,
                    budget: slmConfiguration.dialogueBudget, measurer: runtime)
            } else { compact = false }
        } catch {
            emit(type: "completed", requestId: requestID, text: visibleText, homeSteps: homeSteps, presentation: presentation)
            failContextPreparation(requestID, error: error)
            return result == .committed
        }
        if compact {
            state = .compacting
            emit(type: "context_compacting", requestId: requestID, message: "대화를 정리하고 있어요")
        } else {
            state = .ready
            activeRequestId = nil
            cancelRequested = false
        }
        emit(type: "completed", requestId: requestID, text: visibleText,
             homeSteps: homeSteps, presentation: presentation)
        if compact, let template = lastDialogueTemplate {
            do {
                try await compactDialogueContext(requestID: requestID, template: template,
                    thinkingEnabled: lastDialogueThinking, alreadyAnnounced: true)
            } catch let error as InferenceMemoryDeferred {
                contextCompactionDeferred = true
                state = .ready
                activeRequestId = nil
                cancelRequested = false
                emit(type: "context_warning", requestId: requestID, code: "inference_memory_insufficient",
                     message: error.localizedDescription)
                emit(type: "context_ready", requestId: requestID)
            } catch { failContextPreparation(requestID, error: error) }
        }
        return result == .committed
    }

    private func finishTurnStorageFailure(_ requestID: String) {
        state = .failed
        activeRequestId = nil
        cancelRequested = false
        // The disk checkpoint is still authoritative; a later Initialize reloads it.
        recentTurnsLoaded = false
        emitError(code: "chat_turn_storage_failed", message: "대화 상태를 저장하지 못했습니다. 저장 공간을 확인한 뒤 다시 시도해 주세요.", requestId: requestID)
    }
}
