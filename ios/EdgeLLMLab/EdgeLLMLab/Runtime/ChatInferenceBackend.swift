import Foundation
import LiteRTLM

/// A build/development choice, not automatic device selection or a CPU fallback.
public enum ChatInferenceBackend: String, Sendable {
    case cpu, gpu

    nonisolated var native: Backend { self == .gpu ? .gpu : .cpu() }
}
