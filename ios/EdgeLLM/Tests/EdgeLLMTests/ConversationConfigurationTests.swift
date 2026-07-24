import Testing
@testable import EdgeLLM

@Test func conversationConfigurationHasSafeDefaults() {
    let configuration = ConversationConfiguration()

    #expect(configuration.systemPrompt == nil)
    #expect(configuration.temperature == 0.7)
    #expect(configuration.topK == 40)
    #expect(configuration.topP == 0.95)
}

@Test func runtimeEventsPreservePayloads() {
    #expect(RuntimeEvent.textDelta("hello") == .textDelta("hello"))
    #expect(
        RuntimeEvent.failed(.generationFailed(message: "decoder stopped"))
            == .failed(.generationFailed(message: "decoder stopped"))
    )
}
