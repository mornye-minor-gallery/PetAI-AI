import Foundation

/// Native sessions share executor buffers. A failed GPU transfer can leave a
/// buffer mapped; replacing only the session cannot repair that allocation.
/// Recovery requires a new Engine, after all native operations have finished.
public final class NativeEngineHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    private var detail: String?

    public var requiresRecreation: Bool { lock.withLock { failed } }

    public var failureDetail: String? { lock.withLock { detail } }
    func invalidate(_ detail: String? = nil) { lock.withLock { failed = true; self.detail = detail } }

    func requireUsable() throws {
        if requiresRecreation { throw CachedSessionError.checkpoint(10) }
    }
}
