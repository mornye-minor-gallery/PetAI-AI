import Foundation

extension ChatSessionController {
    func compactDialogueContext(requestID: String, template: DialogueContextTemplate,
                                thinkingEnabled: Bool, resumeGeneration: Bool = false,
                                alreadyAnnounced: Bool = false, admissionOnly: Bool = false) async throws {
        guard let store = recentTurnStore else { throw RecentTurnStorageError.notLoaded }
        // Compaction includes native prefill even when summary generation is off.
        try checkInferenceAdmission(.summary)
        if !admissionOnly { state = .compacting }
        if !alreadyAnnounced && !admissionOnly { emit(type: "context_compacting", requestId: requestID, message: "대화를 정리하고 있어요") }
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                logger.notice("Dialogue compaction in progress")
            }
        }
        defer { heartbeat.cancel() }
        let budget = slmConfiguration.dialogueBudget
        let started = ProcessInfo.processInfo.systemUptime
        let inputBefore = try await runtime.measureInput(template.input(
            entries: routedPersonaSession.contextEntries, summary: routedPersonaSession.summary))
        let plan = try await DialogueContextCompactor.plan(template: template,
            entries: routedPersonaSession.contextEntries, previousSummary: routedPersonaSession.summary,
            budget: budget, measurer: runtime)
        logger.notice("Dialogue compaction selected retained=\(plan.retainedEntries.count) excluded=\(plan.excludedEntries.count) summaryLimit=\(plan.summaryTokenLimit)")
        var summary = plan.previousSummary
        if plan.needsSummaryGeneration {
            do {
                summary = try await runtime.generateDialogueSummary(plan.summaryInput, maximumTokens: plan.summaryTokenLimit)
                if summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    throw UnityBridgeError.invalidRequest
                }
            } catch {
                if error as? RuntimeError == .engineRequiresReload { throw error }
                if error is InferenceMemoryDeferred { throw error }
                // Only summary generation has the approved recent-only fallback.
                // Storage and native prefill failures remain terminal preparation errors.
                logger.error("Dialogue summary failed: \(error.localizedDescription)")
                summary = nil
                emit(type: "context_warning", requestId: requestID, code: "summary_generation_failed",
                     message: "대화를 요약하지 못했어요. 최근 대화로 이어갈게요.")
            }
        }
        let fitted = try await DialogueContextCompactor.finish(plan: plan, summary: summary,
            template: template, budget: budget, measurer: runtime)
        try await runtime.prefillDialogueContext(fitted.modelInput, thinkingEnabled: thinkingEnabled)
        try store.compact(in: &routedPersonaSession, retaining: fitted.retainedEntries,
            summary: fitted.summary, modelIdentifier: dialogueModelIdentifier)
        try await runtime.saveCompletedDialogueCheckpoint()
        logger.notice("Dialogue compaction committed inputBefore=\(inputBefore) inputAfter=\(fitted.inputTokens) retained=\(fitted.retainedEntries.count) seconds=\(ProcessInfo.processInfo.systemUptime - started)")
        contextCompactionDeferred = false
        if admissionOnly {
            state = .admitting
        } else if resumeGeneration {
            state = .generating
            emit(type: "generating", requestId: requestID)
        } else {
            cancelRequested = false
            state = .ready
            activeRequestId = nil
            emit(type: "context_ready", requestId: requestID)
        }
    }

    func failContextPreparation(_ requestID: String, error: Error) {
        logger.error("Dialogue context preparation failed: \(error.localizedDescription)")
        state = .failed
        recentTurnsLoaded = false
        activeRequestId = nil
        cancelRequested = false
        emit(type: "context_failed", requestId: requestID, code: "context_preparation_failed",
             message: error as? RuntimeError == .engineRequiresReload
                ? "대화 엔진을 다시 준비해야 해요. 대화를 다시 열어 주세요."
                : "대화를 정리하지 못했어요. 대화를 다시 열어 주세요.")
    }
}
