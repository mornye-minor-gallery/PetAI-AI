import Testing
@testable import EdgeLLM

@Test func runtimeStartsWithModelRequired() {
    let state = RuntimeState.modelRequired

    #expect(state == .modelRequired)
}

@Test func runtimeFailurePreservesItsMessage() {
    let state = RuntimeState.failed(message: "Model file is missing.")

    #expect(state == .failed(message: "Model file is missing."))
}
