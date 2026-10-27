import Foundation

/// Native consumers freeze the launch selection once. Unity may persist a new
/// preference later, but cannot mutate this process's engine configuration.
public final class ChatModelLaunchSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var selected: ChatModelProfile = .e2b
    private var frozen = false
    public init() {}
    public func configure(_ profile: ChatModelProfile) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !frozen || selected == profile else { return false }
        selected = profile
        return true
    }
    public func capture() -> ChatModelProfile {
        lock.lock(); defer { lock.unlock() }
        frozen = true
        return selected
    }
}
