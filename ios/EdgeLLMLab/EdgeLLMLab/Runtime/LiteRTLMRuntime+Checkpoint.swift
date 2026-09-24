import Foundation
import OSLog
#if canImport(EdgeLLM)
import EdgeLLM
#endif
#if canImport(LiteRTLM)
import LiteRTLM
#endif

extension LiteRTLMRuntime {
    func prepareCheckpointStore(modelURL: URL) {
        do {
            checkpointStore = try KVCheckpointStore.deviceLocal()
            checkpointModelIdentity = KVCheckpointStore.modelIdentity(at: modelURL)
            logger.notice("KV checkpoint storage ready")
        } catch {
            // KV is a disposable acceleration cache, not user history. A storage
            // failure must not make the authoritative conversation unavailable.
            checkpointStore = nil
            checkpointModelIdentity = nil
            logger.error("KV checkpoint disabled: \(error.localizedDescription, privacy: .public)")
        }
    }

    func checkpointIdentity() -> String? {
        checkpointModelIdentity.map {
            KVCheckpointStore.identity(modelIdentity: $0,
                contextTokens: slmConfiguration.dialogueBudget.contextTokens)
        }
    }

    func restoreCheckpointIfAvailable(_ session: CachedSession) throws {
        guard let store = checkpointStore, let identity = checkpointIdentity(), store.exists else { return }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            try store.restore(identity: identity) { try session.transferState(reading: true, transfer: $0) }
            logger.notice("KV checkpoint restored seconds=\(ProcessInfo.processInfo.systemUptime - start, privacy: .public)")
        } catch {
            logger.error("KV checkpoint restore rejected: \(error.localizedDescription, privacy: .public)")
            try store.remove()
            // Native clears partial buffers and token metadata on a failed read.
            // If that cleanup itself failed, continuing inference is unsafe.
            if case CachedSessionError.checkpoint(10) = error { throw error }
            logger.notice("KV checkpoint discarded; full prompt will be recomputed")
        }
    }

    /// Called only after the app commits a completed, visible dialogue turn.
    /// Actor admission remains owned until this synchronous bounded-memory write ends.
    func saveCompletedDialogueCheckpoint() {
        guard activeGenerationID == nil, !isPreparingInput,
              currentState == .ready, let session = conversation as? CachedSession,
              let store = checkpointStore, let identity = checkpointIdentity() else { return }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            try store.save(identity: identity) { try session.transferState(reading: false, transfer: $0) }
            logger.notice("KV checkpoint saved seconds=\(ProcessInfo.processInfo.systemUptime - start, privacy: .public)")
        } catch {
            // Atomic app writes preserve the previous complete cache. The full
            // prompt on the next request safely handles an older matching prefix.
            logger.error("KV checkpoint save failed; completed dialogue kept: \(error.localizedDescription, privacy: .public)")
        }
    }

    func eraseCheckpoint() throws {
        try requireNativeIdle()
        try (checkpointStore ?? KVCheckpointStore.deviceLocal()).remove()
        logger.notice("KV checkpoint removed")
    }
}
