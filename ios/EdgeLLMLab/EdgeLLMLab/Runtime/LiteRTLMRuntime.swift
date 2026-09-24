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
        let value: any TextSession

        init(_ value: any TextSession) {
            self.value = value
        }
    }

    let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EdgeLLMLab",
        category: "LiteRTLMRuntime"
    )
    let slmConfiguration: SLMConfiguration
    var currentState: RuntimeState = .modelRequired
    var engine: Engine?
    var conversation: (any TextSession)?
    var isolatedConversation: Conversation?
    var conversationConfiguration: ConversationConfiguration?
    private var scopedModelURL: URL?
    private var isAccessingSecurityScopedModel = false
    var cancelRequested = false
    var isPreparingInput = false
    var conversationDialogueBudget: DialogueTokenBudget?
    var activeNativeConversation: (any TextSession)?
    var nativeCancellationTask: Task<Void, Never>?
    var activeGenerationID: UUID?
    var activeGenerationTask: Task<Void, Never>?
    var activeContinuation:
        AsyncThrowingStream<String, Error>.Continuation?
    private var cancellationTimeoutTask: Task<Void, Never>?
    let collectNativeBenchmark: Bool
    var latestMetrics: LiteRTLMGenerationMetrics?
    var checkpointStore: KVCheckpointStore?
    var checkpointModelIdentity: String?

    init(
        configuration: SLMConfiguration = .production,
        collectNativeBenchmark: Bool = false
    ) {
        slmConfiguration = configuration
        self.collectNativeBenchmark = collectNativeBenchmark
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
            ExperimentalFlags.optIntoExperimentalAPIs()
            ExperimentalFlags.enableBenchmark = collectNativeBenchmark
            ExperimentalFlags.filterChannelContentFromKvCache = true
            let cacheURL = try runtimeCacheURL()
            let configuration = try EngineConfig(
                modelPath: modelURL.path,
                backend: .cpu(),
                maxNumTokens: slmConfiguration.dialogueBudget.contextTokens,
                cacheDir: cacheURL.path
            )
#if RESOURCE_BENCH
            RuntimeResourceTrace.mark("runtime.configuration", ["context_tokens": String(slmConfiguration.dialogueBudget.contextTokens),
                "output_tokens": String(slmConfiguration.dialogueBudget.outputTokens), "backend": "cpu", "model_file": modelURL.lastPathComponent])
#endif
            let candidate = Engine(engineConfig: configuration)

            try await candidate.initialize()

            engine = candidate
            prepareCheckpointStore(modelURL: modelURL)
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
            conversation = nil
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
                thinkingConfig: ThinkingConfig(
                    enableThinking: configuration.thinkingEnabled
                )
            )

#if RESOURCE_BENCH
            RuntimeResourceTrace.mark("session.replace.begin", [:])
            defer { RuntimeResourceTrace.mark("session.replace.exit", [:]) }
#endif
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

    func generateIsolated(
        systemPrompt: String,
        userMessage: String,
        sampling: SLMConfiguration.Sampling? = nil,
        thinkingEnabled: Bool? = nil,
        maxOutputTokens: Int? = nil
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
                thinkingConfig: ThinkingConfig(
                    enableThinking: thinkingEnabled
                        ?? slmConfiguration.generation.routerThinkingEnabled
                )
            )
            let routeConversation = try await engine.createConversation(
                with: configuration
            )
            try Task.checkCancellation()
            guard !cancelRequested else { throw RuntimeError.generationCancelled }
            isolatedConversation = routeConversation
            activeNativeConversation = routeConversation
            let source = routeConversation.sendMessageStream(
                Message(normalizedUserMessage),
                extraContext: [
                    "enable_thinking": thinkingEnabled
                        ?? slmConfiguration.generation
                            .routerThinkingEnabled,
                ],
                maxOutputTokens: maxOutputTokens
                    ?? slmConfiguration.dialogueBudget.outputTokens,
                thinkingConfig: ThinkingConfig(
                    enableThinking: thinkingEnabled
                        ?? slmConfiguration.generation.routerThinkingEnabled
                )
            )
            var response = ""
            for try await message in source { response += message.toString }
            await waitForNativeCompletion(routeConversation)
            guard activeGenerationID == generationID, !cancelRequested else {
                throw RuntimeError.generationCancelled
            }
            finishIsolatedGeneration(id: generationID)
            return response
        } catch {
            if let activeNativeConversation { await waitForNativeCompletion(activeNativeConversation) }
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
            !cancelRequested
        else {
            return
        }

        cancelRequested = true
        guard let activeConversation = activeNativeConversation else { return }
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
        nativeCancellationTask = Task.detached(priority: .userInitiated) {
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

    func resetConversation() async throws {
        try requireNativeIdle()
        guard let configuration = conversationConfiguration else {
            throw RuntimeError.conversationNotStarted
        }
        try eraseCheckpoint()
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
        activeNativeConversation = nil
        nativeCancellationTask = nil
        cancelRequested = false
        isolatedConversation = nil
        conversation = nil
        conversationConfiguration = nil
        conversationDialogueBudget = nil
        latestMetrics = nil
        checkpointStore = nil
        checkpointModelIdentity = nil
        engine = nil
        releaseSecurityScopedModel()
        currentState = .modelRequired
        logger.notice("LiteRT-LM runtime unloaded")
    }

    func finishGeneration(id: UUID) {
        guard activeGenerationID == id else {
            return
        }

        cancellationTimeoutTask?.cancel()
        cancellationTimeoutTask = nil
        activeGenerationTask = nil
        activeContinuation = nil
        activeGenerationID = nil
        activeNativeConversation = nil
        nativeCancellationTask = nil
        cancelRequested = false
        currentState = .ready
    }

    func finishIsolatedGeneration(id: UUID) {
        guard activeGenerationID == id else { return }
        cancellationTimeoutTask?.cancel()
        cancellationTimeoutTask = nil
        isolatedConversation = nil
        activeGenerationID = nil
        activeNativeConversation = nil
        nativeCancellationTask = nil
        cancelRequested = false
        currentState = .ready
    }

    func finishGeneration(
        id: UUID,
        with error: Error
    ) -> RuntimeError {
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
        activeNativeConversation = nil
        nativeCancellationTask = nil
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
        guard activeGenerationID == id else { return }
        // Failure of the stop request does not establish that inference stopped.
        logger.error("Native cancellation failed; retaining operation until terminal callback: \(error.localizedDescription)")
    }

    private func handleCancellationTimeout(id: UUID) {
        guard activeGenerationID == id, cancelRequested else { return }
        // This is a diagnostic deadline, not permission to release native resources.
        // Unity independently ends its waiting indicator and presents restart guidance.
        logger.error("Cancellation deadline reached; native termination unconfirmed, restart required")
        cancellationTimeoutTask = nil
    }

    func waitForNativeCompletion(_ active: any TextSession) async {
        await active.waitUntilIdle()
        // A final callback can arrive while the C cancellation call is still unwinding.
        if let nativeCancellationTask { await nativeCancellationTask.value }
        // Seal native cancellation admission before returning across an actor await boundary.
        // The generation ID remains owned while callers finish their non-native bookkeeping.
        activeNativeConversation = nil
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

    private func releaseSecurityScopedModel() {
        if isAccessingSecurityScopedModel {
            scopedModelURL?.stopAccessingSecurityScopedResource()
        }

        scopedModelURL = nil
        isAccessingSecurityScopedModel = false
    }
}
