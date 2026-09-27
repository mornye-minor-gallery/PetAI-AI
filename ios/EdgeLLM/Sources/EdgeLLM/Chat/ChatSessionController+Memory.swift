import Foundation

extension ChatSessionController {
    public func requestMemory(requestId: String) {
        guard maintenanceRequestID == nil, !dataExportInProgress, state == .ready, captionTask == nil, let source = captionSource, source.id == requestId,
              let input = ChatMemoryCandidate.input(user: source.user, assistant: source.assistant)
        else {
            emit(type: "memory_candidate", requestId: requestId)
            return
        }
        captionSource = nil // One attempt. Never retained in persona history or written to a native store.
        let generation = UUID()
        captionGeneration = generation
        captionTask = Task {
            let deadline = Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, self.captionGeneration == generation else { return }
                await self.cancelMemory()
                self.emit(type: "memory_candidate", requestId: requestId)
            }
            defer { deadline.cancel() }
            var candidate: ChatMemoryCandidate?
            do {
                try Task.checkCancellation()
                let output = try await runtime.generateIsolated(
                    systemPrompt: ChatMemoryCandidate.systemPrompt, userMessage: input,
                    sampling: nil,
                    thinkingEnabled: false, maxOutputTokens: 384
                )
                try Task.checkCancellation()
                candidate = ChatMemoryCandidate.parse(output)
            } catch {
                // No retry, raw payload logging, chat error, token emission, or reward settlement.
            }
            guard self.captionGeneration == generation else { return }
            self.captionGeneration = nil
            self.captionTask = nil
            var presentation = ChatReplyPresentation.dialogue(visibleText: source.assistant)
            presentation.memory = candidate
            self.emit(type: "memory_candidate", requestId: requestId, presentation: presentation)
        }
    }

    public func cancelMemory() async {
        guard let task = captionTask else { return }
        captionGeneration = nil
        task.cancel()
        await runtime.cancel()
        // Wait for the isolated engine call to unwind before admitting the next chat or unloading.
        await task.value
        captionTask = nil
    }

    func recallMemories(
        userMessage: String,
        excludingTurnIDs: Set<String>
    ) async -> [RetrievedMemoryObservation] {
        diagnostics?.mark("memory.recall.begin", [:])
        do {
            let memories = try await memoryService.recall(
                MemorySearchRequest(
                    scope: memoryScope,
                    query: userMessage,
                    topK: slmConfiguration.memory.recallLimit,
                    minimumSimilarity: slmConfiguration.memory
                        .minimumSimilarity,
                    excludedTurnIDs: excludingTurnIDs
                )
            )
            diagnostics?.mark("memory.recall.exit", [
                "status": "success",
                "recalled_memory_count": String(memories.count)
            ])
            return memories
        } catch {
            logger.error(
                "Memory recall failed; chat continues without recalled context: \(error.localizedDescription)"
            )
            diagnostics?.mark("memory.recall.exit", [
                "status": "error",
                "recalled_memory_count": "0"
            ])
            return []
        }
    }

    func remember(
        userMessage: String,
        sourceMessageID: String,
        label: MemoryGateLabel
    ) async {
        do {
            let result = try await memoryService.remember(
                MemoryWriteRequest(
                    sourceMessageID: sourceMessageID,
                    sessionID: memorySessionID,
                    scope: memoryScope,
                    rawText: userMessage
                ),
                decision: .taggedChat(label)
            )
            logger.debug(
                "Memory write completed status=\(result.status.rawValue)"
            )
        } catch {
            logger.error(
                "Memory write failed; generated response was kept: \(error.localizedDescription)"
            )
        }
    }

}
