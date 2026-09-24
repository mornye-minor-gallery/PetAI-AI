import Foundation
import CLiteRTLM

extension LifecycleTests {
    static func checkpointTests() async throws {
        let session = try CachedSession(engine: Engine(), engineHandle: OpaquePointer(bitPattern: 1)!,
            sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
        do { try session.transferState(reading: false) { _, _ in }; preconditionFailure("fresh session saved") } catch {}
        try session.transferState(reading: true) { _, _ in }
        precondition(test_checkpoint_reads() == 1)
        do { try session.transferState(reading: true) { _, _ in }; preconditionFailure("restored twice") } catch {}
        try session.replaceInput(systemPrompt: "fixed")
        _ = try await run(session, "checkpoint")
        try session.transferState(reading: false) { _, _ in }
        precondition(test_checkpoint_writes() == 1)
        test_set_pending(1)
        let source = session.streamText("checkpoint busy", thinkingEnabled: false, maxOutputTokens: 32)
        while !String(cString: test_input()).contains("checkpoint busy") { await Task.yield() }
        do { try session.transferState(reading: false) { _, _ in }; preconditionFailure("active session saved") } catch {}
        try session.cancel()
        do { for try await _ in source {} } catch {}
        await session.waitUntilIdle()
        do { try session.transferState(reading: false) { _, _ in }; preconditionFailure("cancelled session saved") } catch {}
        test_set_pending(0)
        test_set_checkpoint_error(15)
        let fresh = try CachedSession(engine: Engine(), engineHandle: OpaquePointer(bitPattern: 1)!,
            sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
        do { try fresh.transferState(reading: true) { _, _ in }; preconditionFailure("native error hidden") } catch {}
        test_set_checkpoint_error(0)
        // Native restore guarantees clean state after failure; retry starts from the full prompt.
        try fresh.replaceInput(systemPrompt: "fixed")
        _ = try await run(fresh, "after failed restore")
        precondition(fresh.latestCacheTrace()?.matchingInputPrefixTokens == 0)
        let rejected = try CachedSession(engine: Engine(), engineHandle: OpaquePointer(bitPattern: 1)!,
            sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
        var receivedBytes = 0
        enum TransferFailure: Error { case rejected }
        do {
            try rejected.transferState(reading: true) { pointer, size in
                if pointer != nil { receivedBytes += size }
                else { throw TransferFailure.rejected }
            }
            preconditionFailure("finalization error hidden")
        } catch TransferFailure.rejected {}
        precondition(receivedBytes == 1)
        try rejected.replaceInput(systemPrompt: "fixed")
        _ = try await run(rejected, "after rejected finalization")
        let poisoned = try CachedSession(engine: Engine(), engineHandle: OpaquePointer(bitPattern: 1)!,
            sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
        test_set_checkpoint_error(10)
        do {
            try poisoned.transferState(reading: true) { _, _ in }
            preconditionFailure("cleanup failure hidden")
        } catch CachedSessionError.checkpoint(10) {}
        test_set_checkpoint_error(0)
        do { try poisoned.replaceInput(systemPrompt: "fixed"); preconditionFailure("poisoned session reused") }
        catch CachedSessionError.checkpoint(10) {}
        print("checkpoint admission and recovery tests passed")
    }
}
