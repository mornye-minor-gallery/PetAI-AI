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
    func makeCheckpointStore() throws -> KVCheckpointStore {
        try KVCheckpointStore(directory: runtimeCacheURL().appendingPathComponent("Session"))
    }
    func prepareCheckpointStore(modelIdentity: String) {
        do {
            checkpointStore = try makeCheckpointStore()
            checkpointModelIdentity = modelIdentity
            logger.notice("KV checkpoint storage ready backend=\(self.backend.rawValue, privacy: .public)")
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
                contextTokens: slmConfiguration.dialogueBudget.contextTokens,
                backend: backend.rawValue, engineIdentity: engineIdentity)
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
            removeRejectedCheckpoint(store)
            // Native clears partial buffers and token metadata on a failed read.
            // If that cleanup itself failed, continuing inference is unsafe.
            try requireHealthyEngine()
            logger.notice("KV checkpoint discarded; full prompt will be recomputed")
        }
    }

    /// Called only after the app commits a completed, visible dialogue turn.
    /// Actor admission remains owned until this synchronous bounded-memory write ends.
    func saveCompletedDialogueCheckpoint() throws {
        try requireNativeIdle()
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
            try requireHealthyEngine()
        }
    }

    func eraseCheckpoint() throws {
        try requireNativeIdle()
        try (checkpointStore ?? makeCheckpointStore()).remove()
        try makeDiaryCheckpointStore().remove()
        logger.notice("KV checkpoint removed")
    }

    func requireHealthyEngine() throws {
        guard engine?.health.requiresRecreation == true else { return }
        logger.error("Native engine invalidated: \(self.engine?.health.failureDetail ?? "state transfer failed", privacy: .public)")
        currentState = .failed(message: RuntimeError.engineRequiresReload.localizedDescription)
        throw RuntimeError.engineRequiresReload
    }

    func removeRejectedCheckpoint(_ store: KVCheckpointStore) {
        do { try store.remove() }
        catch { logger.error("Rejected checkpoint removal failed: \(error.localizedDescription, privacy: .public)") }
    }
}
