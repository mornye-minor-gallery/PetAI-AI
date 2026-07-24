import Testing
@testable import EdgeLLM

@Test func missingModelErrorPreservesItsPath() {
    let error = RuntimeError.modelFileMissing(path: "/models/gemma.litertlm")

    #expect(error.errorDescription == "Model file was not found at: /models/gemma.litertlm")
}

@Test func engineInitializationErrorPreservesItsMessage() {
    let error = RuntimeError.engineInitializationFailed(message: "GPU is unavailable.")

    #expect(error.errorDescription == "The inference engine failed to initialize: GPU is unavailable.")
}

@Test func runtimeErrorsRemainDistinct() {
    #expect(RuntimeError.modelNotPrepared != .generationCancelled)
    #expect(RuntimeError.emptyPrompt != .generationCancelled)
    #expect(RuntimeError.conversationNotStarted != .runtimeBusy)
}

@Test func generationErrorPreservesItsMessage() {
    let error = RuntimeError.generationFailed(message: "decoder stopped")

    #expect(error.errorDescription == "Generation failed: decoder stopped")
}

@Test func cancellationTimeoutExplainsRecovery() {
    let error = RuntimeError.cancellationTimedOut(seconds: 10)

    #expect(
        error.errorDescription
            == "Cancellation did not finish within 10 seconds. Fully close and reopen the app before generating again."
    )
}
