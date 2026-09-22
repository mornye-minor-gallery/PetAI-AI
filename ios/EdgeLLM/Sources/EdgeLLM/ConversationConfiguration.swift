public struct ConversationConfiguration: Equatable, Sendable {
    public let systemPrompt: String?
    public let temperature: Float
    public let topK: Int
    public let topP: Float
    public let thinkingEnabled: Bool
    public let maxOutputTokens: Int

    public init(
        systemPrompt: String? = nil,
        temperature: Float = SLMConfiguration.production.generation
            .responseSampling.temperature,
        topK: Int = SLMConfiguration.production.generation
            .responseSampling.samplerTopK,
        topP: Float = SLMConfiguration.production.generation
            .responseSampling.topP,
        maxOutputTokens: Int = SLMConfiguration.production.generation
            .maxOutputTokens,
        thinkingEnabled: Bool = SLMConfiguration.production.generation.responseThinkingDefault
    ) {
        self.systemPrompt = systemPrompt
        self.thinkingEnabled = thinkingEnabled
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
    }
}
