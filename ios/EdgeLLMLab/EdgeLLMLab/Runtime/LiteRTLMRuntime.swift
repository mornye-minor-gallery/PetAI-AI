import Foundation
import OSLog

#if canImport(EdgeLLM)
import EdgeLLM
#endif

#if canImport(LiteRTLM)
import LiteRTLM
#endif

struct TopKTelemetrySummary: Sendable, Equatable, Encodable {
    let tokenCount: Int
    let droppedEventCount: Int
    let maximumCandidateCount: Int
    let averageTopKEntropy: Float
    let averageTop1Top2Margin: Float
    let minimumTop1Top2Margin: Float
    let sampledFromTop1Rate: Float
    let metricTemperature: Float
}

actor LiteRTLMRuntime: LLMRuntime {
    private struct TopKTelemetryAccumulator {
        var tokenCount = 0
        var droppedEventCount = 0
        var maximumCandidateCount = 0
        var entropySum: Float = 0
        var marginSum: Float = 0
        var minimumMargin = Float.greatestFiniteMagnitude
        var sampledFromTop1Count = 0
        var metricTemperature: Float = 1

        mutating func append(_ drain: TopKTelemetryDrain) {
            droppedEventCount += drain.droppedEventCount
            for event in drain.events {
                tokenCount += 1
                maximumCandidateCount = max(
                    maximumCandidateCount,
                    event.candidates.count
                )
                entropySum += event.topKEntropy
                marginSum += event.top1Top2Margin
                minimumMargin = min(
                    minimumMargin,
                    event.top1Top2Margin
                )
                metricTemperature = event.metricTemperature
                if event.candidates.first?.tokenID
                    == event.sampledTokenID
                {
                    sampledFromTop1Count += 1
                }
            }
        }

        func summary() -> TopKTelemetrySummary? {
            guard tokenCount > 0 else {
                return nil
            }
            let count = Float(tokenCount)
            return TopKTelemetrySummary(
                tokenCount: tokenCount,
                droppedEventCount: droppedEventCount,
                maximumCandidateCount: maximumCandidateCount,
                averageTopKEntropy: entropySum / count,
                averageTop1Top2Margin: marginSum / count,
                minimumTop1Top2Margin: minimumMargin,
                sampledFromTop1Rate:
                    Float(sampledFromTop1Count) / count,
                metricTemperature: metricTemperature
            )
        }
    }

    private final class SendableConversation: @unchecked Sendable {
        let value: Conversation

        init(_ value: Conversation) {
            self.value = value
        }
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EdgeLLMLab",
        category: "LiteRTLMRuntime"
    )
    private let slmConfiguration: SLMConfiguration
    private var currentState: RuntimeState = .modelRequired
    private var engine: Engine?
    private var conversation: Conversation?
    private var isolatedConversation: Conversation?
    private var conversationConfiguration: ConversationConfiguration?
    private var scopedModelURL: URL?
    private var isAccessingSecurityScopedModel = false
    private var cancelRequested = false
    private var activeGenerationID: UUID?
    private var activeGenerationTask: Task<Void, Never>?
    private var activeContinuation:
        AsyncThrowingStream<String, Error>.Continuation?
    private var cancellationTimeoutTask: Task<Void, Never>?
    private var topKTelemetryAccumulator = TopKTelemetryAccumulator()

    init(configuration: SLMConfiguration = .production) {
        slmConfiguration = configuration
    }

    private var cancellationTimeoutSeconds: Int {
        slmConfiguration.runtimeSafety.cancellationTimeoutSeconds
    }

    var state: RuntimeState {
        currentState
    }

    func prepare(modelURL: URL) async throws {
        try await unload()

        currentState = .preparingModel
        isAccessingSecurityScopedModel = modelURL.startAccessingSecurityScopedResource()
        scopedModelURL = modelURL

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            let error = RuntimeError.modelFileMissing(path: modelURL.path)
            releaseSecurityScopedModel()
            currentState = .failed(message: error.localizedDescription)
            throw error
        }

        do {
            let cacheURL = try runtimeCacheURL()
            let configuration = try EngineConfig(
                modelPath: modelURL.path,
                backend: .cpu(),
                cacheDir: cacheURL.path
            )
            let candidate = Engine(engineConfig: configuration)

            try await candidate.initialize()

            engine = candidate
            currentState = .ready
        } catch {
            releaseSecurityScopedModel()
            currentState = .failed(message: error.localizedDescription)
            throw RuntimeError.engineInitializationFailed(
                message: error.localizedDescription
            )
        }
    }

    func startConversation(
        configuration: ConversationConfiguration
    ) async throws {
        guard let engine else {
            throw RuntimeError.modelNotPrepared
        }

        do {
            let sampler = try SamplerConfig(
                topK: configuration.topK,
                topP: configuration.topP,
                temperature: configuration.temperature
            )
            let nativeConfiguration = ConversationConfig(
                systemMessage: configuration.systemPrompt.map {
                    Message($0, role: .system)
                },
                samplerConfig: sampler,
                filterChannelContentFromKVCache: true,
                topKTelemetryCandidateCount:
                    configuration.topKTelemetryCandidateCount,
                maxOutputTokens: configuration.maxOutputTokens
            )

            conversation = try await engine.createConversation(
                with: nativeConfiguration
            )
            conversationConfiguration = configuration
            currentState = .ready
        } catch {
            currentState = .failed(message: error.localizedDescription)
            throw RuntimeError.conversationInitializationFailed(
                message: error.localizedDescription
            )
        }
    }

    func generateStream(
        prompt: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await generateStream(
            prompt: prompt,
            thinkingEnabled: slmConfiguration.generation
                .responseThinkingDefault
        )
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
        guard currentState != .generating else {
            throw RuntimeError.runtimeBusy
        }
        guard engine != nil else {
            throw RuntimeError.modelNotPrepared
        }
        guard let conversation else {
            throw RuntimeError.conversationNotStarted
        }

        cancelRequested = false
        currentState = .generating
        let generationID = UUID()
        let startedAt = Date()
        activeGenerationID = generationID

        logger.notice(
            "Generation requested id=\(generationID.uuidString, privacy: .public) promptCharacters=\(normalizedPrompt.count) thinkingEnabled=\(thinkingEnabled, privacy: .public)"
        )
        logger.notice(
            "Submitting native stream id=\(generationID.uuidString, privacy: .public)"
        )
        let source = conversation.sendMessageStream(
            Message(normalizedPrompt),
            extraContext: ["enable_thinking": thinkingEnabled]
        )
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

            do {
                for try await message in source {
                    try Task.checkCancellation()
                    // LiteRT-LM exposes internal reasoning through
                    // Message.channels. Only normal response content is
                    // forwarded to Unity or EdgeLLM Lab.
                    let text = message.toString
                    guard !text.isEmpty else {
                        continue
                    }

                    chunkCount += 1
                    characterCount += text.count

                    if !receivedFirstChunk {
                        receivedFirstChunk = true
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

                finishGeneration(id: generationID)
                logger.notice(
                    "Generation completed id=\(generationID.uuidString, privacy: .public) elapsedSeconds=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3)) chunks=\(chunkCount) characters=\(characterCount)"
                )
                continuation.finish()
            } catch {
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

    func generateIsolated(
        systemPrompt: String,
        userMessage: String,
        sampling: SLMConfiguration.Sampling? = nil,
        thinkingEnabled: Bool? = nil
    ) async throws -> String {
        let normalizedSystemPrompt = systemPrompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedUserMessage = userMessage.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !normalizedSystemPrompt.isEmpty,
            !normalizedUserMessage.isEmpty
        else {
            throw RuntimeError.emptyPrompt
        }
        guard currentState != .generating else {
            throw RuntimeError.runtimeBusy
        }
        guard let engine else {
            throw RuntimeError.modelNotPrepared
        }

        let generationID = UUID()
        cancelRequested = false
        activeGenerationID = generationID
        currentState = .generating

        do {
            let resolvedSampling = sampling
                ?? slmConfiguration.generation.deterministicSampling
            let sampler = try SamplerConfig(
                topK: resolvedSampling.samplerTopK,
                topP: resolvedSampling.topP,
                temperature: resolvedSampling.temperature
            )
            let configuration = ConversationConfig(
                systemMessage: Message(
                    normalizedSystemPrompt,
                    role: .system
                ),
                samplerConfig: sampler,
                filterChannelContentFromKVCache: true,
                maxOutputTokens: slmConfiguration.generation
                    .maxOutputTokens
            )
            let routeConversation = try await engine.createConversation(
                with: configuration
            )
            isolatedConversation = routeConversation
            let response = try await routeConversation.sendMessage(
                Message(normalizedUserMessage),
                extraContext: [
                    "enable_thinking": thinkingEnabled
                        ?? slmConfiguration.generation
                            .routerThinkingEnabled,
                ]
            )
            guard activeGenerationID == generationID else {
                throw RuntimeError.generationCancelled
            }
            finishIsolatedGeneration(id: generationID)
            return response.toString
        } catch {
            let wasCancelled = cancelRequested
                || error is CancellationError
                || (error as? RuntimeError) == .generationCancelled
            finishIsolatedGeneration(id: generationID)
            if wasCancelled {
                throw RuntimeError.generationCancelled
            }
            throw RuntimeError.generationFailed(
                message: error.localizedDescription
            )
        }
    }

    func cancel() async {
        guard
            currentState == .generating,
            let generationID = activeGenerationID,
            let activeConversation = isolatedConversation ?? conversation
        else {
            return
        }

        cancelRequested = true
        logger.notice(
            "Cancellation requested id=\(generationID.uuidString, privacy: .public)"
        )

        cancellationTimeoutTask?.cancel()
        cancellationTimeoutTask = Task {
            do {
                try await Task.sleep(
                    nanoseconds:
                        UInt64(cancellationTimeoutSeconds)
                        * 1_000_000_000
                )
                handleCancellationTimeout(id: generationID)
            } catch is CancellationError {
                return
            } catch {
                logger.error(
                    "Cancellation timer failed id=\(generationID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let sendableConversation = SendableConversation(activeConversation)
        Task.detached(priority: .userInitiated) {
            do {
                try sendableConversation.value.cancel()
                await self.nativeCancellationReturned(id: generationID)
            } catch {
                await self.nativeCancellationFailed(
                    id: generationID,
                    error: error
                )
            }
        }
    }

    func resetTopKTelemetrySummary() {
        _ = conversation?.drainTopKTelemetry()
        topKTelemetryAccumulator = TopKTelemetryAccumulator()
    }

    func takeTopKTelemetrySummary() -> TopKTelemetrySummary? {
        captureTopKTelemetry()
        let summary = topKTelemetryAccumulator.summary()
        topKTelemetryAccumulator = TopKTelemetryAccumulator()
        return summary
    }

    func resetConversation() async throws {
        guard let configuration = conversationConfiguration else {
            throw RuntimeError.conversationNotStarted
        }
        guard currentState != .generating else {
            logger.error(
                "Conversation reset rejected while generation is active"
            )
            throw RuntimeError.runtimeBusy
        }

        conversation = nil
        try await startConversation(configuration: configuration)
    }

    func unload() async throws {
        guard currentState != .generating else {
            logger.error(
                "Unload rejected while generation is active; use cancel first"
            )
            throw RuntimeError.runtimeBusy
        }

        logger.notice("Unloading LiteRT-LM runtime")
        cancellationTimeoutTask?.cancel()
        cancellationTimeoutTask = nil
        activeGenerationTask?.cancel()
        activeGenerationTask = nil
        activeContinuation?.finish(throwing: RuntimeError.generationCancelled)
        activeContinuation = nil
        activeGenerationID = nil
        cancelRequested = false
        isolatedConversation = nil
        conversation = nil
        conversationConfiguration = nil
        engine = nil
        releaseSecurityScopedModel()
        currentState = .modelRequired
        logger.notice("LiteRT-LM runtime unloaded")
    }

    private func finishGeneration(id: UUID) {
        captureTopKTelemetry()
        guard activeGenerationID == id else {
            return
        }

        cancellationTimeoutTask?.cancel()
        cancellationTimeoutTask = nil
        activeGenerationTask = nil
        activeContinuation = nil
        activeGenerationID = nil
        cancelRequested = false
        currentState = .ready
    }

    private func finishIsolatedGeneration(id: UUID) {
        guard activeGenerationID == id else { return }
        cancellationTimeoutTask?.cancel()
        cancellationTimeoutTask = nil
        isolatedConversation = nil
        activeGenerationID = nil
        cancelRequested = false
        currentState = .ready
    }

    private func finishGeneration(
        id: UUID,
        with error: Error
    ) -> RuntimeError {
        captureTopKTelemetry()
        guard activeGenerationID == id else {
            return error as? RuntimeError
                ?? .generationFailed(message: error.localizedDescription)
        }

        let wasCancelled = cancelRequested || error is CancellationError
        cancellationTimeoutTask?.cancel()
        cancellationTimeoutTask = nil
        activeGenerationTask = nil
        activeContinuation = nil
        activeGenerationID = nil
        cancelRequested = false
        isolatedConversation = nil

        if wasCancelled {
            currentState = .ready
            return .generationCancelled
        }

        let mappedError = RuntimeError.generationFailed(
            message: error.localizedDescription
        )
        currentState = .failed(message: error.localizedDescription)
        return mappedError
    }

    private func nativeCancellationReturned(id: UUID) {
        guard activeGenerationID == id else {
            return
        }

        logger.notice(
            "Native cancellation call returned id=\(id.uuidString, privacy: .public); waiting for stream termination"
        )
    }

    private func nativeCancellationFailed(id: UUID, error: Error) {
        guard activeGenerationID == id else {
            return
        }

        cancellationTimeoutTask?.cancel()
        cancellationTimeoutTask = nil
        activeGenerationTask?.cancel()
        activeGenerationTask = nil
        activeGenerationID = nil
        cancelRequested = false
        isolatedConversation = nil

        let mappedError = RuntimeError.generationFailed(
            message: "Cancellation failed: \(error.localizedDescription)"
        )
        currentState = .failed(message: mappedError.localizedDescription)
        activeContinuation?.finish(throwing: mappedError)
        activeContinuation = nil
        logger.error(
            "Native cancellation failed id=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
    }

    private func handleCancellationTimeout(id: UUID) {
        guard activeGenerationID == id, cancelRequested else {
            return
        }

        let timeoutError = RuntimeError.cancellationTimedOut(
            seconds: cancellationTimeoutSeconds
        )
        activeGenerationTask?.cancel()
        activeGenerationTask = nil
        activeGenerationID = nil
        cancelRequested = false
        isolatedConversation = nil
        currentState = .failed(message: timeoutError.localizedDescription)
        activeContinuation?.finish(throwing: timeoutError)
        activeContinuation = nil
        cancellationTimeoutTask = nil

        logger.error(
            "Cancellation timed out id=\(id.uuidString, privacy: .public) seconds=\(self.cancellationTimeoutSeconds); app restart required"
        )
    }

    private func runtimeCacheURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheURL = baseURL.appendingPathComponent(
            "LiteRTLM",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: cacheURL,
            withIntermediateDirectories: true
        )
        return cacheURL
    }

    private func captureTopKTelemetry() {
        guard let drain = conversation?.drainTopKTelemetry() else {
            return
        }
        topKTelemetryAccumulator.append(drain)
    }

    private func releaseSecurityScopedModel() {
        if isAccessingSecurityScopedModel {
            scopedModelURL?.stopAccessingSecurityScopedResource()
        }

        scopedModelURL = nil
        isAccessingSecurityScopedModel = false
    }
}

#if canImport(LiteRTLM) || canImport(CLiteRTLM)
extension LiteRTLMRuntime: NativeToolProposalGenerating {
    func generateFunctionCall(
        _ request: NativeToolGenerationRequest
    ) async throws -> NativeToolFunctionCall {
        guard currentState != .generating else {
            throw RuntimeError.runtimeBusy
        }
        guard let engine else {
            throw RuntimeError.modelNotPrepared
        }

        currentState = .generating
        do {
            try await LiteRTLMNativeToolCallCapture.shared.begin(
                expectedTool: request.selectedTool
            )
            let sampling = slmConfiguration.generation
                .deterministicSampling
            let sampler = try SamplerConfig(
                topK: sampling.samplerTopK,
                topP: sampling.topP,
                temperature: sampling.temperature
            )
            let configuration = ConversationConfig(
                systemMessage: Message(
                    request.systemPrompt,
                    role: .system
                ),
                tools: [
                    LiteRTLMNativeToolFactory.makeTool(
                        for: request.selectedTool
                    ),
                ],
                samplerConfig: sampler,
                filterChannelContentFromKVCache: true,
                maxOutputTokens: slmConfiguration.generation
                    .maxOutputTokens
            )
            let toolConversation = try await engine.createConversation(
                with: configuration
            )
            _ = try await toolConversation.sendMessage(
                Message(request.userMessage),
                extraContext: [
                    "enable_thinking": request.reasoningEnabled,
                ]
            )
            let call = try await LiteRTLMNativeToolCallCapture.shared.finish()
            currentState = .ready
            return call
        } catch {
            if let call = try? await
                LiteRTLMNativeToolCallCapture.shared.finish()
            {
                currentState = .ready
                return call
            }
            await LiteRTLMNativeToolCallCapture.shared.cancel()
            currentState = .ready
            throw error
        }
    }
}
#endif
