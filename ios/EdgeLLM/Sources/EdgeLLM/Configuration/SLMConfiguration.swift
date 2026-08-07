public struct SLMConfiguration: Equatable, Sendable {
    public enum SceneRouterMode: String, Equatable, Sendable {
        case embeddingV2
        case gemmaLegacy
    }

    public struct Memory: Equatable, Sendable {
        public let recallLimit: Int
        public let promptTokenBudget: Int
        public let minimumSimilarity: Float

        public init(
            recallLimit: Int,
            promptTokenBudget: Int,
            minimumSimilarity: Float
        ) {
            precondition(recallLimit > 0)
            precondition(promptTokenBudget > 0)
            precondition((-1...1).contains(minimumSimilarity))
            self.recallLimit = recallLimit
            self.promptTokenBudget = promptTokenBudget
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
        public let recentMessageLimit: Int
        public let sceneRouterMode: SceneRouterMode

        public init(
            recentMessageLimit: Int,
            sceneRouterMode: SceneRouterMode
        ) {
            precondition(recentMessageLimit >= 0)
            self.recentMessageLimit = recentMessageLimit
            self.sceneRouterMode = sceneRouterMode
        }
    }

    public struct Diagnostics: Equatable, Sendable {
        public let telemetryCandidateCount: Int

        public init(telemetryCandidateCount: Int) {
            precondition((1...16).contains(telemetryCandidateCount))
            self.telemetryCandidateCount = telemetryCandidateCount
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
    public let diagnostics: Diagnostics
    public let runtimeSafety: RuntimeSafety

    public init(
        id: String,
        memory: Memory,
        generation: Generation,
        persona: Persona,
        diagnostics: Diagnostics,
        runtimeSafety: RuntimeSafety
    ) {
        precondition(!id.isEmpty)
        self.id = id
        self.memory = memory
        self.generation = generation
        self.persona = persona
        self.diagnostics = diagnostics
        self.runtimeSafety = runtimeSafety
    }
}

public extension SLMConfiguration {
    static let production = SLMConfiguration(
        id: "petai-slm-v1",
        memory: Memory(
            recallLimit: 10,
            promptTokenBudget: 10_000,
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
            maxOutputTokens: 4_096,
            responseThinkingDefault: false,
            routerThinkingEnabled: false,
            toolReasoningEnabled: false
        ),
        persona: Persona(
            recentMessageLimit: 6,
            sceneRouterMode: .embeddingV2
        ),
        diagnostics: Diagnostics(telemetryCandidateCount: 8),
        runtimeSafety: RuntimeSafety(cancellationTimeoutSeconds: 10)
    )
}
