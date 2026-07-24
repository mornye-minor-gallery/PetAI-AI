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
    private let cancellationTimeoutSeconds = 10
    private var currentState: RuntimeState = .modelRequired
    private var engine: Engine?
    private var conversation: Conversation?
    private var conversationConfiguration: ConversationConfiguration?
    private var scopedModelURL: URL?
    private var isAccessingSecurityScopedModel = false
    private var cancelRequested = false
    private var activeGenerationID: UUID?
    private var activeGenerationTask: Task<Void, Never>?
    private var activeContinuation:
        AsyncThrowingStream<String, Error>.Continuation?
    private var cancellationTimeoutTask: Task<Void, Never>?

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
                samplerConfig: sampler
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
            "Generation requested id=\(generationID.uuidString, privacy: .public) promptCharacters=\(normalizedPrompt.count)"
        )
        logger.notice(
            "Submitting native stream id=\(generationID.uuidString, privacy: .public)"
        )
        let source = conversation.sendMessageStream(
            Message(normalizedPrompt)
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

    func cancel() async {
        guard
            currentState == .generating,
            let generationID = activeGenerationID,
            let conversation
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

        let sendableConversation = SendableConversation(conversation)
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
        conversation = nil
        conversationConfiguration = nil
        engine = nil
        releaseSecurityScopedModel()
        currentState = .modelRequired
        logger.notice("LiteRT-LM runtime unloaded")
    }

    private func finishGeneration(id: UUID) {
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

    private func finishGeneration(
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
        cancelRequested = false

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

    private func releaseSecurityScopedModel() {
        if isAccessingSecurityScopedModel {
            scopedModelURL?.stopAccessingSecurityScopedResource()
        }

        scopedModelURL = nil
        isAccessingSecurityScopedModel = false
    }
}
