import Foundation

public enum InferenceOperation: String, Sendable {
    case dialogue, summary, diary, memoryCaption
}

public enum InferenceMemoryPressure: String, Sendable {
    case normal, warning, critical
}

/// An admission observation is not a reservation. Query again for the next job;
/// never interrupt an active native engine or mutate its KV buffers here.
public struct InferenceMemoryAdmission: Sendable {
    public let requiredBytes: UInt64
    public init(requiredBytes: UInt64) { self.requiredBytes = requiredBytes }

    public func check(availableBytes: UInt64, pressure: InferenceMemoryPressure) throws {
        guard pressure == .normal, availableBytes >= requiredBytes else {
            throw InferenceMemoryDeferred(availableBytes: availableBytes,
                requiredBytes: requiredBytes, pressure: pressure)
        }
    }
}

public struct InferenceMemoryDeferred: Error, LocalizedError, Equatable, Sendable {
    public let availableBytes: UInt64
    public let requiredBytes: UInt64
    public let pressure: InferenceMemoryPressure

    public init(availableBytes: UInt64, requiredBytes: UInt64, pressure: InferenceMemoryPressure) {
        self.availableBytes = availableBytes
        self.requiredBytes = requiredBytes
        self.pressure = pressure
    }

    public var errorDescription: String? {
        "지금은 메모리 여유가 부족해요. 잠시 뒤 다시 시도해 주세요."
    }
}
