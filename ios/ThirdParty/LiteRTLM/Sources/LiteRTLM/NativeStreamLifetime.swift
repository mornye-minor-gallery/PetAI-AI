import Foundation

/// Native ownership survives consumer cancellation, parse failures, and UI deadlines.
/// One lifetime spans every tool round; only the native terminal path finishes it.
final class NativeStreamLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var cancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { lock.withLock { waiters.count } }
    var isActive: Bool { lock.withLock { active } }
    var isCancellationRequested: Bool { lock.withLock { cancelled } }

    func begin() {
        lock.withLock {
            precondition(!active, "Conversation already has a native operation")
            active = true
            cancelled = false
        }
    }

    func requestCancellation() { lock.withLock { cancelled = true } }

    func finish() {
        let pending = lock.withLock {
            active = false
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
    }

    func waitUntilFinished() async {
        // Deliberately not cancellation-aware: cancelling a waiter cannot stop native code.
        await withCheckedContinuation { continuation in
            let finished = lock.withLock {
                if !active { return true }
                waiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
    }
}
