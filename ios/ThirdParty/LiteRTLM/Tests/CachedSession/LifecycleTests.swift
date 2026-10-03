import Foundation
import CLiteRTLM

@main struct LifecycleTests {
    static func run(_ session: CachedSession, _ prompt: String) async throws -> String {
        var result = ""
        for try await text in session.streamText(prompt, thinkingEnabled: false, maxOutputTokens: 32) { result += text }
        await session.waitUntilIdle()
        return result
    }
    static func main() async throws {
        let session = try CachedSession(engine: Engine(), engineHandle: OpaquePointer(bitPattern: 1)!,
            sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 0), maxOutputTokens: 32)
        try session.replaceInput(systemPrompt: "fixed")
        let first = try await run(session, "기억 A")
        precondition(first == "안녕")
        precondition(test_created() == 1 && test_rewinds() == 1)
        precondition(String(cString: test_input()).hasPrefix("fixed<|turn>user\n기억 A")) // BOS supplied once by native.
        try session.replaceInput(systemPrompt: "fixed")
        _ = try await run(session, "기억 B")
        precondition(test_created() == 1 && test_rewinds() == 2)
        precondition(!String(cString: test_input()).contains("기억 A"))
        precondition(session.latestCacheTrace()!.matchingInputPrefixTokens > 0)
        try session.replaceInput(systemPrompt: "fixed")
        _ = try await run(session, "기억 B")
        precondition(test_rewinds() == 3, "identical input still rewinds past old output")
        _ = try await run(session, "retry")
        precondition(String(cString: test_input()).contains("기억 B<turn|>\n<|turn>model\n안녕<turn|>\n<|turn>user\nretry"))
        try session.replaceInput(systemPrompt: "fixed")
        _ = try await run(session, "짧음")
        precondition(!String(cString: test_input()).contains("retry"))
        try session.replaceInput(systemPrompt: "fixed")
        let limited = try await run(session, "limit")
        precondition(limited == "안녕" && session.latestCacheTrace()?.finishReason == "token_limit")
        test_set_start_error(7)
        do { _ = try await run(session, "failure"); preconditionFailure() } catch {}
        await session.waitUntilIdle()
        test_set_start_error(0)
        try session.replaceInput(systemPrompt: "fixed")
        _ = try await run(session, "recovery")
        precondition(session.latestCacheTrace()!.matchingInputPrefixTokens == 0)
        test_set_pending(1)
        let source = session.streamText("cancel", thinkingEnabled: true, maxOutputTokens: 32)
        // Wait for native admission using observable test state, not a fixed sleep.
        while !String(cString: test_input()).contains("cancel") { await Task.yield() }
        do { try session.replaceInput(systemPrompt: "wrong"); preconditionFailure() } catch {}
        try session.cancel()
        do { for try await _ in source {}; preconditionFailure() } catch {}
        await session.waitUntilIdle()
        test_set_pending(0)
        try session.replaceInput(systemPrompt: "fixed")
        _ = try await run(session, "after cancel")
        precondition(test_created() == 1)
        let orderedPrefix = [Message("fixed", role: .system), Message("history", role: .user),
            Message("scene A", role: .system)]
        try session.replaceInput(systemPrompt: nil, initialMessages: orderedPrefix)
        let measured = try await session.measureInput("current A", thinkingEnabled: false)
        _ = try await run(session, "current A")
        let rendered = String(cString: test_input())
        precondition(rendered.hasPrefix("<|turn>system\nfixed<turn|>\n<|turn>user\nhistory<turn|>\n<|turn>system\nscene A<turn|>\n<|turn>user\ncurrent A"))
        precondition(measured == rendered.utf8.count + "BOS".utf8.count)
        try session.replaceInput(systemPrompt: nil, initialMessages: [
            orderedPrefix[0], orderedPrefix[1], Message("scene B", role: .system)])
        _ = try await run(session, "current B")
        precondition(!String(cString: test_input()).contains("scene A"))
        precondition(!String(cString: test_input()).contains("current A"))
        precondition(session.latestCacheTrace()!.matchingInputPrefixTokens > 0)
        print("cached session native boundary tests passed")
        try await checkpointTests()
    }
}
