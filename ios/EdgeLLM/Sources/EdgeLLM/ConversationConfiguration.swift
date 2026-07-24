public struct ConversationConfiguration: Equatable, Sendable {
    public let systemPrompt: String?
    public let temperature: Float
    public let topK: Int
    public let topP: Float

    public init(
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topK: Int = 40,
        topP: Float = 0.95
    ) {
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
    }
}
