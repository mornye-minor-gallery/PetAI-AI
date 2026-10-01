import Foundation

extension ChatSessionController {
    public func requestDiary(json: String) {
        struct Request: Decodable { let requestId: String; let localDate: String }
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(json.utf8)) else { return }
        requestDiary(requestId: request.requestId, localDate: request.localDate)
    }

    public func listDiaries(requestId: String) async {
        guard !requestId.isEmpty else { return }
        do {
            let values = try await memoryService.allDiaries()
            emit(type: "diary_list", requestId: requestId,
                 diaries: values.map(NativeDiaryEntry.init))
        } catch {
            logger.error("Diary list failed: \(error.localizedDescription)")
            emit(type: "diary_failed", requestId: requestId,
                 code: "diary_storage_failed", message: "일기를 불러오지 못했어요.")
        }
    }

    public func requestDiary(requestId: String, localDate: String) {
        guard !requestId.isEmpty else { return }
        guard diaryTask == nil else {
            emit(type: "diary_failed", requestId: requestId,
                 code: "diary_busy", message: DailyDiaryError.busy.localizedDescription)
            return
        }
        diaryTask = Task {
            await makeDiary(requestId: requestId, localDate: localDate)
            diaryTask = nil
        }
    }

    private func makeDiary(requestId: String, localDate: String) async {
        do {
            let day = try DailyDiaryDay(localDate)
            let characterID = memoryScope.characterID
            if let existing = try await memoryService.diary(characterID: characterID, localDate: day.key) {
                emit(type: "diary_completed", requestId: requestId, diary: NativeDiaryEntry(existing))
                return
            }
            guard maintenanceRequestID == nil, !dataExportInProgress, !isUnloading,
                  activeRequestId == nil, dialogueTasks.isEmpty, captionTask == nil,
                  preparationTask == nil, state == .ready else { throw DailyDiaryError.busy }
            let observations = try await memoryService.activeObservations(
                in: memoryScope, from: day.start, to: day.end)
            guard !observations.isEmpty else { throw DailyDiaryError.noMemories }
            var random = SystemRandomNumberGenerator()
            var selected = DailyDiaryPrompt.select(observations, using: &random)
            let capacity = slmConfiguration.dialogueBudget.contextTokens - 384
            var input = DailyDiaryPrompt.input(localDate: day.key, observations: selected)
            while !selected.isEmpty {
                let tokens = try await runtime.countDiaryInputTokens(
                    systemPrompt: DailyDiaryPrompt.system, userMessage: input)
                if tokens <= capacity { break }
                selected.removeFirst() // Keep newer evidence when the selected set exceeds the model window.
                input = DailyDiaryPrompt.input(localDate: day.key, observations: selected)
            }
            guard !selected.isEmpty else { throw DailyDiaryError.invalidDraft }
            emit(type: "diary_progress", requestId: requestId, message: "일기를 정리하고 있어요.")
            let heartbeat = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    emit(type: "diary_progress", requestId: requestId, message: "일기를 정리하고 있어요.")
                }
            }
            defer { heartbeat.cancel() }
            let output = try await runtime.generateDiary(
                systemPrompt: DailyDiaryPrompt.system, userMessage: input)
            guard let draft = DailyDiaryDraft.parse(output) else { throw DailyDiaryError.invalidDraft }
            let stored = try await memoryService.insertDiaryIfAbsent(
                characterID: characterID, localDate: day.key, draft: draft)
            emit(type: "diary_completed", requestId: requestId, diary: NativeDiaryEntry(stored))
        } catch {
            logger.error("Diary creation failed: \(error.localizedDescription)")
            emit(type: "diary_failed", requestId: requestId,
                 code: error is DailyDiaryError ? "diary_unavailable" : "diary_failed",
                 message: (error as? DailyDiaryError)?.localizedDescription ?? "일기를 만들지 못했어요. 다시 시도해 주세요.")
        }
    }
}
