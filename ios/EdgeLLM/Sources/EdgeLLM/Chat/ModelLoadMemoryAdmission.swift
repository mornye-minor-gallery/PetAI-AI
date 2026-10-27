import Foundation

public struct ModelLoadMemoryAdmission: Sendable {
    public let requiredBytes: UInt64
    public init(requiredBytes: UInt64) { self.requiredBytes = requiredBytes }

    public func check(availableBytes: UInt64) throws {
        guard availableBytes >= requiredBytes else {
            throw ModelLoadMemoryDeferred(availableBytes: availableBytes, requiredBytes: requiredBytes)
        }
    }
}

/// A load was deferred, not a missing or damaged model file. The caller may retry
/// with a fresh OS observation; the observation is not a reservation of memory.
public struct ModelLoadMemoryDeferred: Error, LocalizedError, Equatable, Sendable {
    public let availableBytes: UInt64
    public let requiredBytes: UInt64

    public init(availableBytes: UInt64, requiredBytes: UInt64) {
        self.availableBytes = availableBytes
        self.requiredBytes = requiredBytes
    }

    public var errorDescription: String? {
        "지금은 메모리 여유가 부족해 대화를 준비하지 못했어요. 다른 기능은 계속 사용할 수 있어요. 잠시 뒤 다시 시도해 주세요."
    }
}
