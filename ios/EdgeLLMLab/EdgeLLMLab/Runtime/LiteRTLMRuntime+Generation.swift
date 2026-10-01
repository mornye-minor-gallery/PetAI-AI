import Foundation
#if canImport(OSLog)
import OSLog
#endif
#if canImport(EdgeLLM)
import EdgeLLM
#endif
#if canImport(LiteRTLM)
import LiteRTLM
#endif

extension LiteRTLMRuntime {
    func generateStream(
        prompt: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let configuration = conversationConfiguration else { throw RuntimeError.conversationNotStarted }
        return try await generateStream(prompt: prompt, thinkingEnabled: configuration.thinkingEnabled)
    }

    func generateStream(
        prompt: String,
        thinkingEnabled: Bool
    ) async throws -> AsyncThrowingStream<String, Error> {
        let normalizedPrompt = prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !normalizedPrompt.isEmpty else {
            throw RuntimeError.emptyPrompt
        }
        try requireNativeIdle()
        guard engine != nil else {
            throw RuntimeError.modelNotPrepared
        }
        guard let conversation else {
            throw RuntimeError.conversationNotStarted
        }

        cancelRequested = false
        if let budget = conversationDialogueBudget {
            guard conversationConfiguration?.thinkingEnabled == thinkingEnabled else {
                throw RuntimeError.generationFailed(message: "Prepared dialogue thinking configuration changed")
            }
            isPreparingInput = true
            do {
                try await checkConversationBudget(conversation, prompt: normalizedPrompt, budget: budget)
                try Task.checkCancellation()
                guard !cancelRequested else { throw RuntimeError.generationCancelled }
                isPreparingInput = false
            } catch {
                isPreparingInput = false
                throw error
            }
        }
        currentState = .generating
        let generationID = UUID()
        let startedAt = Date()
        let monotonicStart = ProcessInfo.processInfo.systemUptime
        activeGenerationID = generationID
        latestMetrics = nil

        let kvTokensBefore: Int?
        do {
            let value = try conversation.getTokenCount()
            kvTokensBefore = value >= 0 ? value : nil
        } catch {
            kvTokensBefore = nil
            if !(conversation is CachedSession) { logger.error(
                "KV token measurement before generation failed id=\(generationID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            ) }
        }

        logger.notice(
            "Generation requested id=\(generationID.uuidString, privacy: .public) promptCharacters=\(normalizedPrompt.count) thinkingEnabled=\(thinkingEnabled, privacy: .public)"
        )
        logger.notice(
            "Submitting native stream id=\(generationID.uuidString, privacy: .public)"
        )
        activeNativeConversation = conversation
        let source = conversation.streamText(normalizedPrompt, thinkingEnabled: thinkingEnabled,
            maxOutputTokens: conversationConfiguration!.maxOutputTokens)
        logger.notice(
            "Native stream accepted id=\(generationID.uuidString, privacy: .public)"
        )

        let (stream, continuation) =
            AsyncThrowingStream<String, Error>.makeStream()
        activeContinuation = continuation

        let generationTask = Task {
            var chunkCount = 0
            var characterCount = 0
            var receivedFirstChunk = false
            var firstResponseSeconds: Double?

            do {
                for try await text in source {
                    try Task.checkCancellation()
                    // Both session adapters expose only visible response text.
                    guard !text.isEmpty else {
                        continue
                    }

                    chunkCount += 1
                    characterCount += text.count

                    if !receivedFirstChunk {
                        receivedFirstChunk = true
                        firstResponseSeconds = ProcessInfo.processInfo.systemUptime - monotonicStart
                        logger.notice(
                            "First chunk received id=\(generationID.uuidString, privacy: .public) ttftSeconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3)) characters=\(text.count)"
                        )
                    } else {
                        logger.debug(
                            "Chunk received id=\(generationID.uuidString, privacy: .public) chunk=\(chunkCount) totalCharacters=\(characterCount)"
                        )
                    }

                    continuation.yield(text)
                }

                await waitForNativeCompletion(conversation)
                captureNativeMetrics(
                    conversation,
                    generationID: generationID,
                    kvTokensBefore: kvTokensBefore, firstResponseSeconds: firstResponseSeconds,
                    elapsedSeconds: ProcessInfo.processInfo.systemUptime - monotonicStart
                )
                finishGeneration(id: generationID)
                logger.notice(
                    "Generation completed id=\(generationID.uuidString, privacy: .public) elapsedSeconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3)) chunks=\(chunkCount) characters=\(characterCount)"
                )
                continuation.finish()
            } catch {
                await waitForNativeCompletion(conversation)
                let mappedError = finishGeneration(
                    id: generationID,
                    with: error
                )
                logger.error(
                    "Generation ended with error id=\(generationID.uuidString, privacy: .public) elapsedSeconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3)) error=\(mappedError.localizedDescription, privacy: .public)"
                )
                continuation.finish(throwing: mappedError)
            }
        }
        activeGenerationTask = generationTask

        return stream
    }

    func latestGenerationMetrics() -> LiteRTLMGenerationMetrics? {
        latestMetrics
    }

    func captureNativeMetrics(
        _ conversation: any TextSession,
        generationID: UUID,
        kvTokensBefore: Int?, firstResponseSeconds: Double?, elapsedSeconds: Double
    ) {
        let metrics = LiteRTLMGenerationMetrics.capture(
            conversation: conversation,
            kvTokensBefore: kvTokensBefore,
            includeBenchmark: collectNativeBenchmark, firstResponseSeconds: firstResponseSeconds,
            generationElapsedSeconds: elapsedSeconds
        )
        latestMetrics = metrics
        logger.notice(
            "Native inference metrics id=\(generationID.uuidString, privacy: .public) kvBefore=\(metrics.kvTokensBefore ?? -1, privacy: .public) kvAfter=\(metrics.kvTokensAfter ?? -1, privacy: .public) prefillTokens=\(metrics.prefillTokens ?? -1, privacy: .public) prefillTokensPerSecond=\(metrics.prefillTokensPerSecond ?? -1, privacy: .public) decodeTokens=\(metrics.decodeTokens ?? -1, privacy: .public) decodeTokensPerSecond=\(metrics.decodeTokensPerSecond ?? -1, privacy: .public) nativeTTFTSeconds=\(metrics.nativeTTFTSeconds ?? -1, privacy: .public)"
        )
        if let cache = metrics.cache {
            logger.notice("Cached session id=\(cache.sessionID, privacy: .public) inputTokens=\(cache.inputTokens, privacy: .public) matchingInputPrefixTokens=\(cache.matchingInputPrefixTokens, privacy: .public) firstResponseSeconds=\(metrics.firstResponseSeconds ?? -1, privacy: .public) elapsedSeconds=\(metrics.generationElapsedSeconds ?? -1, privacy: .public) kvCounter=unsupported finishReason=\(cache.finishReason ?? "unknown", privacy: .public)")
        }
        if let error = metrics.measurementError {
            logger.error(
                "Native inference metrics incomplete id=\(generationID.uuidString, privacy: .public) error=\(error, privacy: .public)"
            )
        }
    }

}
