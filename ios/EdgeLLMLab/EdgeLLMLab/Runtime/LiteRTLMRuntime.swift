import Foundation
import OSLog

#if canImport(EdgeLLM)
import EdgeLLM
#endif

#if canImport(LiteRTLM)
import LiteRTLM
#endif

actor LiteRTLMRuntime: LLMRuntime {
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
    let slmConfiguration: SLMConfiguration
    var currentState: RuntimeState = .modelRequired
    var engine: Engine?
    var conversation: Conversation?
    private var isolatedConversation: Conversation?
    var conversationConfiguration: ConversationConfiguration?
    private var scopedModelURL: URL?
    private var isAccessingSecurityScopedModel = false
    var cancelRequested = false
    var isPreparingInput = false
    var conversationDialogueBudget: DialogueTokenBudget?
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
        isPreparingInput ? .preparingInput : currentState
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
                maxNumTokens: slmConfiguration.dialogueBudget.contextTokens,
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
        try requireNativeIdle()
        isPreparingInput = true
        defer { isPreparingInput = false }
        try await replaceConversation(configuration: configuration)
    }

    func replaceConversation(configuration: ConversationConfiguration) async throws {
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
                maxOutputTokens: configuration.maxOutputTokens,
                thinkingEnabled: configuration.thinkingEnabled
            )

            conversation = try await engine.createConversation(
                with: nativeConfiguration
            )
            conversationConfiguration = configuration
            conversationDialogueBudget = nil
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
        try requireNativeIdle()
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
        if isPreparingInput { cancelRequested = true; return }
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
        try requireNativeIdle()
        guard let configuration = conversationConfiguration else {
            throw RuntimeError.conversationNotStarted
        }
        let budget = conversationDialogueBudget
        conversation = nil
        try await startConversation(configuration: configuration)
        conversationDialogueBudget = budget
    }

    func unload() async throws {
        try requireNativeIdle()
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
        conversationDialogueBudget = nil
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
