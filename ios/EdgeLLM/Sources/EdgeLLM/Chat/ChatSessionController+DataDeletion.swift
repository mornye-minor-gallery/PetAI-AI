import Foundation

extension ChatSessionController {
    public func beginDataDeletion(id: String, reset: Bool, removeModels: Bool) {
        guard !dataExportInProgress, diaryTask == nil else {
            emit(type: "maintenance_failed", requestId: id,
                 message: "진행 중인 데이터 작업이 끝난 뒤 다시 시도해 주세요.")
            return
        }
        guard maintenanceTask == nil else { return }
        maintenanceRequestID = id // Remains locked across failure and Unity's local commit.
        abandonPendingTurnDecision()
        maintenanceTask = Task {
            let heartbeat = Task {
                var seconds = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    seconds += 5
                    emit(type: "maintenance_progress", requestId: id,
                         message: seconds >= 15 ? "정리가 지연되고 있습니다. 종료되지 않으면 앱을 다시 실행해 주세요." : "진행 중인 작업의 종료를 기다리고 있어요.")
                }
            }
            defer { heartbeat.cancel(); maintenanceTask = nil }
            do {
                guard !isUnloading else { throw DataDeletionError.runtimeBusy }
                if reset {
                    #if PETAI_TEST_TOOLS
                    try await platform.lockForTestReset()
                    #else
                    throw DataDeletionError.testToolsDisabled
                    #endif
                }
                emit(type: "maintenance_progress", requestId: id, message: "진행 중인 대화와 기억 저장을 정리하고 있어요.")
                if let preparationTask { await preparationTask.value }
                await cancel()
                // Completed replies can still be writing long-term memory. Drain every writer,
                // while allowing normal follow-up dialogue outside maintenance.
                let pendingDialogues = Array(dialogueTasks.values)
                for task in pendingDialogues { await task.value }
                await cancelMemory()
                try await runtime.eraseCheckpoint()
                captionSource = nil
                emit(type: "maintenance_progress", requestId: id, message: "기억 저장소를 지우고 있어요.")
                try await memoryService.eraseAllMemories()
                if reset {
                    #if PETAI_TEST_TOOLS
                    try await runtime.unload()
                    await memoryService.close()
                    try await platform.resetTestData(removeModels: removeModels)
                    routedPersonaSession.removeAll()
                    recentTurnStore = nil
                    recentTurnsLoaded = false
                    state = .modelRequired
                    #endif
                }
                emit(type: "maintenance_ready", requestId: id)
            } catch {
                emit(type: "maintenance_failed", requestId: id, message: error.localizedDescription)
            }
        }
    }

    public func finishDataDeletion(id: String) {
        guard maintenanceRequestID == id, maintenanceTask == nil else { return }
        maintenanceRequestID = nil
        emit(type: "maintenance_completed", requestId: id)
    }
}

enum DataDeletionError: LocalizedError {
    case testToolsDisabled, downloadBusy, verificationFailed, runtimeBusy
    var errorDescription: String? {
        switch self {
        case .runtimeBusy: "이전 작업 정리가 끝난 뒤 다시 시도해 주세요."
        case .testToolsDisabled: "이 빌드는 테스트 초기화를 지원하지 않습니다."
        case .downloadBusy: "모델 다운로드가 끝난 뒤 초기화를 다시 실행해 주세요."
        case .verificationFailed: "삭제 결과를 확인하지 못했습니다. 다시 시도해 주세요."
        }
    }
}
