import Foundation
#if canImport(OSLog)
import OSLog
#endif
#if os(Android)
import Crypto
#else
import CryptoKit
#endif
#if canImport(EdgeLLM)
import EdgeLLM
#endif
#if canImport(LiteRTLM)
import LiteRTLM
#endif

extension LiteRTLMRuntime {
    func countDiaryInputTokens(systemPrompt: String, userMessage: String) async throws -> Int {
        try requireNativeIdle()
        guard let engine else { throw RuntimeError.modelNotPrepared }
        return try await engine.measureTextPrompt(systemPrompt: systemPrompt,
            userPrompt: userMessage, thinkingEnabled: false).totalTokens
    }

    func generateDiary(systemPrompt: String, userMessage: String) async throws -> String {
        try requireNativeIdle()
        guard let engine, let modelIdentity = checkpointModelIdentity else {
            throw RuntimeError.modelNotPrepared
        }
        let generationID = UUID()
        activeGenerationID = generationID
        cancelRequested = false
        currentState = .generating
        // The completed dialogue checkpoint remains on disk. Release its native KV
        // before allocating the isolated diary session on the same engine.
        conversation = nil
        conversationDialogueBudget = nil
        do {
            let sampling = slmConfiguration.generation.deterministicSampling
            let sampler = try SamplerConfig(topK: sampling.samplerTopK, topP: sampling.topP,
                temperature: sampling.temperature)
            let session = try await engine.createCachedSession(sampler: sampler, maxOutputTokens: 384)
            activeNativeConversation = session
            let store = try makeDiaryCheckpointStore()
            let promptDigest = SHA256.hash(data: Data(systemPrompt.utf8)).map { String(format: "%02x", $0) }.joined()
            let identity = KVCheckpointStore.identity(modelIdentity: modelIdentity,
                contextTokens: slmConfiguration.dialogueBudget.contextTokens) + ":diary-prefix-v1:" + promptDigest
            if store.exists {
                do {
                    try store.restore(identity: identity) { try session.transferState(reading: true, transfer: $0) }
                    logger.notice("Diary fixed-prefix checkpoint restored")
                } catch {
                    logger.error("Diary prefix restore rejected: \(error.localizedDescription, privacy: .public)")
                    try store.remove()
                    if case CachedSessionError.checkpoint(10) = error { throw error }
                    try await session.primeSystemPrompt(systemPrompt, thinkingEnabled: false)
                    try store.save(identity: identity) { try session.transferState(reading: false, transfer: $0) }
                }
            } else {
                try await session.primeSystemPrompt(systemPrompt, thinkingEnabled: false)
                try store.save(identity: identity) { try session.transferState(reading: false, transfer: $0) }
            }
            try session.replaceInput(systemPrompt: systemPrompt)
            guard !cancelRequested else { throw RuntimeError.generationCancelled }
            var output = ""
            for try await text in session.streamText(userMessage, thinkingEnabled: false, maxOutputTokens: 384) {
                output += text
            }
            await session.waitUntilIdle()
            guard !cancelRequested else { throw RuntimeError.generationCancelled }
            finishIsolatedGeneration(id: generationID)
            return output
        } catch {
            if let activeNativeConversation { await activeNativeConversation.waitUntilIdle() }
            let wasCancelled = cancelRequested || error is CancellationError
            finishIsolatedGeneration(id: generationID)
            if wasCancelled { throw RuntimeError.generationCancelled }
            throw error
        }
    }

    func makeDiaryCheckpointStore() throws -> KVCheckpointStore {
        if let cacheDirectory {
            return try KVCheckpointStore(directory: cacheDirectory.appendingPathComponent("DiaryPrefix"))
        }
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try KVCheckpointStore(directory: caches.appendingPathComponent("LiteRTLM/DiaryPrefix"))
    }
}
