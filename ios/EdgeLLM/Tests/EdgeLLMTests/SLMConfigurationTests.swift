import Testing

@testable import EdgeLLM

@Test
func productionSLMConfigurationKeepsProductTuningInOnePlace() {
    let configuration = SLMConfiguration.production

    #expect(configuration.id == "petai-slm-v1")
    #expect(configuration.memory.recallLimit == 10)
    #expect(configuration.memory.promptTokenBudget == 10_000)
    #expect(configuration.memory.minimumSimilarity == 0.3)
    #expect(configuration.generation.responseSampling.temperature == 0.7)
    #expect(configuration.generation.responseSampling.samplerTopK == 40)
    #expect(configuration.generation.responseSampling.topP == 1)
    #expect(configuration.generation.deterministicSampling.temperature == 0)
    #expect(configuration.generation.maxOutputTokens == 4_096)
    #expect(!configuration.generation.responseThinkingDefault)
    #expect(!configuration.generation.routerThinkingEnabled)
    #expect(!configuration.generation.toolReasoningEnabled)
    #expect(configuration.persona.recentMessageLimit == 6)
    #expect(configuration.diagnostics.telemetryCandidateCount == 8)
    #expect(configuration.runtimeSafety.cancellationTimeoutSeconds == 10)
}
