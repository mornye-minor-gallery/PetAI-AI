import Foundation

@main struct Tests {
    static func main() async {
        let lifetime = NativeStreamLifetime()
        lifetime.begin()
        // Cancelling a Swift consumer must not release native ownership.
        let waiting = Task { await lifetime.waitUntilFinished() }
        while lifetime.waitingCount != 1 { await Task.yield() }
        waiting.cancel()
        assert(lifetime.isActive)
        lifetime.requestCancellation()
        assert(lifetime.isCancellationRequested)
        assert(lifetime.isActive)
        lifetime.finish()
        await waiting.value
        assert(!lifetime.isActive)
        // Completion before waiter registration must also return immediately.
        await lifetime.waitUntilFinished()
        lifetime.begin()
        assert(!lifetime.isCancellationRequested)
        let waiters = (0..<20).map { _ in Task { await lifetime.waitUntilFinished() } }
        while lifetime.waitingCount != 20 { await Task.yield() }
        lifetime.finish()
        for waiter in waiters { await waiter.value }
        print("native lifetime: PASS (cancelled waiter, terminal, late waiter, reuse, concurrent waiters)")
    }
}
