import Foundation

public enum RuntimeError: Error, Equatable, Sendable {
    case modelFileMissing(path: String)
    case modelNotPrepared
    case conversationNotStarted
    case runtimeBusy
    case emptyPrompt
    case generationCancelled
    case engineInitializationFailed(message: String)
    case conversationInitializationFailed(message: String)
    case generationFailed(message: String)
    case cancellationTimedOut(seconds: Int)
}

extension RuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelFileMissing(let path):
            "Model file was not found at: \(path)"
        case .modelNotPrepared:
            "The model is not prepared."
        case .conversationNotStarted:
            "A conversation has not been started."
        case .runtimeBusy:
            "The runtime is already generating a response."
        case .emptyPrompt:
            "The prompt must not be empty."
        case .generationCancelled:
            "Generation was cancelled."
        case .engineInitializationFailed(let message):
            "The inference engine failed to initialize: \(message)"
        case .conversationInitializationFailed(let message):
            "The conversation failed to initialize: \(message)"
        case .generationFailed(let message):
            "Generation failed: \(message)"
        case .cancellationTimedOut(let seconds):
            "Cancellation did not finish within \(seconds) seconds. Fully close and reopen the app before generating again."
        }
    }
}
