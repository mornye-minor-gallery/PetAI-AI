import Foundation
import CLiteRTLM

extension LifecycleTests {
    static func compactionPrefillTests() async throws {
        let session = try CachedSession(engine: Engine(), engineHandle: OpaquePointer(bitPattern: 1)!,
            sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
        try session.replaceInput(systemPrompt: nil, initialMessages: [
            Message("고정 지침", role: .system), Message("요약과 최근 원문", role: .user),
            Message("현재 상태", role: .system)])
        let before = test_prefill_count()
        try await session.prefillInput("회수 기억", thinkingEnabled: false)
        precondition(test_prefill_count() == before + 1)
        let input = String(cString: test_prefill())
        precondition(input.hasPrefix("<|turn>system\n고정 지침<turn|>\n<|turn>user\n요약과 최근 원문"))
        precondition(input.contains("<|turn>system\n현재 상태"))
        precondition(session.latestCacheTrace()?.finishReason == "prefill")
        try session.transferState(reading: false) { _, _ in }
        try session.replaceInput(systemPrompt: nil, initialMessages: [Message("고정 지침", role: .system)])
        _ = try await run(session, "다음 질문")
        precondition(String(cString: test_input()).contains("다음 질문"))
        precondition(session.latestCacheTrace()?.finishReason == "stop")
        print("compaction prefill boundary tests passed")
    }

    static func checkpointTests() async throws {
        let prefix = try CachedSession(engine: Engine(), engineHandle: OpaquePointer(bitPattern: 1)!,
            sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
        try await prefix.primeSystemPrompt("일기 고정 지침", thinkingEnabled: false)
        precondition(test_prefill_count() == 1 && String(cString: test_prefill()) == "일기 고정 지침")
        try prefix.transferState(reading: false) { _, _ in }
        let resumed = try CachedSession(engine: Engine(), engineHandle: OpaquePointer(bitPattern: 1)!,
            sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
        try resumed.transferState(reading: true) { _, _ in }
        try resumed.replaceInput(systemPrompt: "일기 고정 지침")
        _ = try await run(resumed, "날짜별 기억")
        precondition(test_prefill_count() == 1, "restored prefix must skip prefill")
        let session = try CachedSession(engine: Engine(), engineHandle: OpaquePointer(bitPattern: 1)!,
            sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
        do { try session.transferState(reading: false) { _, _ in }; preconditionFailure("fresh session saved") } catch {}
        try session.transferState(reading: true) { _, _ in }
        precondition(test_checkpoint_reads() == 2)
        do { try session.transferState(reading: true) { _, _ in }; preconditionFailure("restored twice") } catch {}
        try session.replaceInput(systemPrompt: "fixed")
        _ = try await run(session, "checkpoint")
        try session.transferState(reading: false) { _, _ in }
        precondition(test_checkpoint_writes() == 2)
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
        let sharedEngine = Engine()
        let sibling = try CachedSession(engine: sharedEngine, engineHandle: OpaquePointer(bitPattern: 1)!,
            sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
        let failedSave = try CachedSession(engine: sharedEngine, engineHandle: OpaquePointer(bitPattern: 1)!,
            sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
        try failedSave.replaceInput(systemPrompt: "fixed")
        _ = try await run(failedSave, "completed before GPU transfer failure")
        test_set_checkpoint_error(10)
        do { try failedSave.transferState(reading: false) { _, _ in }; preconditionFailure("fatal save hidden") }
        catch CachedSessionError.checkpoint(10) {}
        test_set_checkpoint_error(0)
        do { try failedSave.replaceInput(systemPrompt: "fixed"); preconditionFailure("fatal save reused engine") }
        catch CachedSessionError.checkpoint(10) {}
        precondition(sharedEngine.health.failureDetail == "injected buffer transfer failure")
        do { try sibling.replaceInput(systemPrompt: "fixed"); preconditionFailure("sibling reused failed executor") }
        catch CachedSessionError.checkpoint(10) {}
        do { try sibling.transferState(reading: true) { _, _ in }; preconditionFailure("failed executor restored") }
        catch CachedSessionError.checkpoint(10) {}
        do { _ = try await run(sibling, "blocked"); preconditionFailure("failed executor streamed") }
        catch CachedSessionError.checkpoint(10) {}
        do {
            _ = try CachedSession(engine: sharedEngine, engineHandle: OpaquePointer(bitPattern: 1)!,
                sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
            preconditionFailure("new session reused failed executor")
        } catch CachedSessionError.checkpoint(10) {}
        print("checkpoint admission and recovery tests passed")
    }
}
