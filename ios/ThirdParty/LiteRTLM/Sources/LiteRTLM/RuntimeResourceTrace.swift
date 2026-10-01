#if RESOURCE_BENCH
import Foundation

/// Only present in measurement builds. Fields describe calls, never inferred cache bytes.
public enum RuntimeResourceTrace {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var sink: (@Sendable (String, [String: String]) -> Void)?
    }
    private static let storage = Storage()
    public static func install(_ sink: (@Sendable (String, [String: String]) -> Void)?) {
        storage.lock.lock(); storage.sink = sink; storage.lock.unlock()
    }
    public static func mark(_ stage: String, _ fields: [String: String] = [:]) {
        storage.lock.lock(); let sink = storage.sink; storage.lock.unlock()
        sink?(stage, fields)
    }
}
#endif
