import Foundation

extension ChatSessionController {
    public func beginDataExport() {
        guard exportTask == nil, !dataExportInProgress,
              activeRequestId == nil, dialogueTasks.isEmpty, captionTask == nil, diaryTask == nil,
              preparationTask == nil, maintenanceRequestID == nil, !isUnloading,
              state != .loading, state != .generating else {
            logger.notice("Data export rejected because the runtime is busy")
            Task { await platform.showExportError("대화나 기억 저장이 끝난 뒤 다시 시도해 주세요.") }
            return
        }

        // Claim admission before the first suspension. The share sheet retains
        // this snapshot until dismissal, so deletion and new writes wait too.
        dataExportInProgress = true
        exportTask = Task {
            defer { dataExportInProgress = false; exportTask = nil }
            var temporaryFile: TemporaryChatDataExportFile?
            do {
                let recent = try (recentTurnStore ?? platform.recentTurnStore())
                    .load()?.recentEntries ?? []
                let memories = try await memoryService.allActiveObservations()
                let diaries = try await memoryService.allDiaries()
                let data = try ChatDataExport(recentEntries: recent, activeMemories: memories, diaries: diaries)
                    .jsonData()
                let file = try TemporaryChatDataExportFile(data: data,
                    temporaryRoot: FileManager.default.temporaryDirectory)
                temporaryFile = file
                try await platform.share(file.fileURL)
            } catch {
                logger.error("Data export failed error=\(error.localizedDescription)")
                await platform.showExportError("데이터를 내보내지 못했습니다. 저장 공간을 확인하고 다시 시도해 주세요.")
            }
            if let temporaryFile {
                do { try temporaryFile.remove() }
                catch { logger.error("Could not remove temporary export error=\(error.localizedDescription)") }
            }
        }
    }
}
