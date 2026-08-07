public struct ConversationConfiguration: Equatable, Sendable {
    public let systemPrompt: String?
    public let temperature: Float
    public let topK: Int
    public let topP: Float
    public let maxOutputTokens: Int
    public let topKTelemetryCandidateCount: Int?

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
        topKTelemetryCandidateCount: Int? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
        self.topKTelemetryCandidateCount = topKTelemetryCandidateCount
    }
}
