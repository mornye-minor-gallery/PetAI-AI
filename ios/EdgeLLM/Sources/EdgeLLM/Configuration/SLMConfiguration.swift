public struct SLMConfiguration: Equatable, Sendable {
    public struct Memory: Equatable, Sendable {
        public let recallLimit: Int
        public let promptByteBudget: Int
        public let minimumSimilarity: Float

        public init(
            recallLimit: Int,
            promptByteBudget: Int,
            minimumSimilarity: Float
        ) {
            precondition(recallLimit > 0)
            precondition(promptByteBudget > 0)
            precondition((-1...1).contains(minimumSimilarity))
            self.recallLimit = recallLimit
            self.promptByteBudget = promptByteBudget
            self.minimumSimilarity = minimumSimilarity
        }
    }

    public struct Sampling: Equatable, Sendable {
        public let temperature: Float
        public let samplerTopK: Int
        public let topP: Float

        public init(
            temperature: Float,
            samplerTopK: Int,
            topP: Float
        ) {
            precondition(temperature >= 0)
            precondition(samplerTopK > 0)
            precondition((0...1).contains(topP))
            self.temperature = temperature
            self.samplerTopK = samplerTopK
            self.topP = topP
        }
    }

    public struct Generation: Equatable, Sendable {
        public let responseSampling: Sampling
        public let deterministicSampling: Sampling
        public let maxOutputTokens: Int
        public let responseThinkingDefault: Bool
        public let routerThinkingEnabled: Bool
        public let toolReasoningEnabled: Bool

        public init(
            responseSampling: Sampling,
            deterministicSampling: Sampling,
            maxOutputTokens: Int,
            responseThinkingDefault: Bool,
            routerThinkingEnabled: Bool,
            toolReasoningEnabled: Bool
        ) {
            precondition(maxOutputTokens > 0)
            self.responseSampling = responseSampling
            self.deterministicSampling = deterministicSampling
            self.maxOutputTokens = maxOutputTokens
            self.responseThinkingDefault = responseThinkingDefault
            self.routerThinkingEnabled = routerThinkingEnabled
            self.toolReasoningEnabled = toolReasoningEnabled
        }
    }

    public struct Persona: Equatable, Sendable {
        public let recentTurnLimit: Int

        public init(recentTurnLimit: Int) {
            precondition(recentTurnLimit >= 0)
            self.recentTurnLimit = recentTurnLimit
        }
    }

    public struct RuntimeSafety: Equatable, Sendable {
        public let cancellationTimeoutSeconds: Int

        public init(cancellationTimeoutSeconds: Int) {
            precondition(cancellationTimeoutSeconds > 0)
            self.cancellationTimeoutSeconds = cancellationTimeoutSeconds
        }
    }

    public let id: String
    public let memory: Memory
    public let generation: Generation
    public let persona: Persona
    public let runtimeSafety: RuntimeSafety
    public let dialogueBudget: DialogueTokenBudget
    public let authoredText: DialogueTextSettings?
    public let authorsNote: AuthorsNoteSettings?
    public let worldInfo: WorldInfoSettings?

    public init(
        id: String,
        memory: Memory,
        generation: Generation,
        persona: Persona,
        runtimeSafety: RuntimeSafety,
        dialogueBudget: DialogueTokenBudget = .production,
        authorsNote: AuthorsNoteSettings? = nil,
        worldInfo: WorldInfoSettings? = nil,
        authoredText: DialogueTextSettings? = nil
    ) {
        precondition(!id.isEmpty)
        self.id = id
        self.memory = memory
        self.generation = generation
        self.persona = persona
        self.runtimeSafety = runtimeSafety
        self.dialogueBudget = dialogueBudget
        self.authorsNote = authorsNote
        self.worldInfo = worldInfo
        self.authoredText = authoredText
    }
}

public extension SLMConfiguration {
    static let production = SLMConfiguration(
        id: "petai-slm-v1",
        memory: Memory(
            recallLimit: 10,
            promptByteBudget: 10_000,
            minimumSimilarity: 0.3
        ),
        generation: Generation(
            responseSampling: Sampling(
                temperature: 0.7,
                samplerTopK: 40,
                topP: 1
            ),
            deterministicSampling: Sampling(
                temperature: 0,
                samplerTopK: 40,
                topP: 1
            ),
            maxOutputTokens: DialogueTokenBudget.production.outputTokens,
            responseThinkingDefault: false,
            routerThinkingEnabled: false,
            toolReasoningEnabled: false
        ),
        // One accepted user request is one turn, even when its answer is interrupted.
        persona: Persona(recentTurnLimit: 20),
        // Provisional UX deadline; tune after device cancellation-latency measurements.
        runtimeSafety: RuntimeSafety(cancellationTimeoutSeconds: 15)
    )
}
