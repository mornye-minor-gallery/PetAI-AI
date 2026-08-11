import Foundation
import Testing

@testable import EdgeLLM

private actor ClassificationEmbedderStub: ClassificationEmbeddingProviding {
    nonisolated let modelID = NativeToolRouterArtifactRegistry.expectedModelID
    nonisolated let dimension = 2

    private let vector: [Float]
    private var invocationCount = 0

    init(vector: [Float]) {
        self.vector = vector
    }

    func embedClassification(_ text: String) -> [Float] {
        invocationCount += 1
        return vector
    }

    func count() -> Int { invocationCount }
}

@Test
func nativeToolRouterRegistryLoadsFrozenTwoStageArtifact() throws {
    let pipeline = try NativeToolRouterArtifactRegistry().load()

    #expect(pipeline.artifactID == "toolroutebench-two-stage-v1-retrospective")
    #expect(pipeline.actionability.inputDimension == 768)
    #expect(pipeline.actionability.hiddenUnits == 64)
    #expect(pipeline.actionability.threshold == Float(0.5099999904632568))
    #expect(pipeline.selector.dimension == 768)
    #expect(pipeline.selector.prototypeCount == 84)
}

@Test
func actionabilityMLPUsesReluSigmoidAndThreshold() throws {
    let classifier = try makeActionabilityMLP()

    guard case .call(let callProbability) = try classifier.classify([1, 0]) else {
        Issue.record("Expected CALL")
        return
    }
    guard case .noCall(let noCallProbability) = try classifier.classify([0, 1]) else {
        Issue.record("Expected NO_CALL")
        return
    }

    #expect(callProbability > 0.99)
    #expect(noCallProbability < 0.01)
}

@Test
func twoStagePipelineStopsBeforeToolSelectionForNoCall() throws {
    let selector = try NativeToolEmbeddingSelector(
        dimension: 2,
        routes: [
            NativeToolEmbeddingRouteDefinition(
                tool: .getStepCount,
                threshold: 0.8,
                prototypeOffset: 0,
                prototypeCount: 1
            ),
        ],
        prototypes: [0, 1]
    )
    let pipeline = NativeToolRoutingPipeline(
        artifactID: "test",
        actionability: try makeActionabilityMLP(),
        selector: selector
    )

    #expect(try pipeline.route([0, 1]) == .normal)
}

@Test
func twoStagePipelineSelectsOneToolOrReportsConflict() throws {
    let selector = try NativeToolEmbeddingSelector(
        dimension: 2,
        routes: [
            NativeToolEmbeddingRouteDefinition(
                tool: .getStepCount,
                threshold: 0.6,
                prototypeOffset: 0,
                prototypeCount: 1
            ),
            NativeToolEmbeddingRouteDefinition(
                tool: .createTimer,
                threshold: 0.6,
                prototypeOffset: 1,
                prototypeCount: 1
            ),
        ],
        prototypes: [1, 0, 0, 1]
    )
    let pipeline = NativeToolRoutingPipeline(
        artifactID: "test",
        actionability: try makeActionabilityMLP(),
        selector: selector
    )

    #expect(try pipeline.route([1, 0]) == .tool(.getStepCount))
    #expect(
        try pipeline.route([1, 1])
            == .conflict([.getStepCount, .createTimer])
    )
}

@Test
func embeddingRouterCreatesOneClassificationEmbeddingPerUtterance() async throws {
    let embedder = ClassificationEmbedderStub(vector: [1, 0])
    let selector = try NativeToolEmbeddingSelector(
        dimension: 2,
        routes: [
            NativeToolEmbeddingRouteDefinition(
                tool: .createTimer,
                threshold: 0.8,
                prototypeOffset: 0,
                prototypeCount: 1
            ),
        ],
        prototypes: [1, 0]
    )
    let router = EmbeddingMLPNativeToolRouter(
        embedder: embedder,
        pipeline: NativeToolRoutingPipeline(
            artifactID: "test",
            actionability: try makeActionabilityMLP(),
            selector: selector
        )
    )

    #expect(try await router.route("20초 타이머 맞춰 줘") == .tool(.createTimer))
    #expect(await embedder.count() == 1)
}

@Test
func nativeToolRouterRegistryRejectsChangedManifest() {
    let registry = NativeToolRouterArtifactRegistry { fileName in
        fileName == "native_tool_router_v1.json" ? Data("{}".utf8) : nil
    }

    #expect(throws: NativeToolRoutingError.self) {
        _ = try registry.load()
    }
}

@Test
func frozenActionabilityArtifactMatchesPythonProbabilitiesAndRoutes() throws {
    let pipeline = try NativeToolRouterArtifactRegistry().load()
    let url = try #require(
        Bundle.module.url(
            forResource: "native_tool_actionability_parity_v1",
            withExtension: "f32"
        )
    )
    let data = try Data(contentsOf: url)
    let cases: [(probability: Float, route: NativeToolRoute)] = [
        (0.9949618577957153, .tool(.getStepCount)),
        (0.12166988104581833, .normal),
        (0.012534575536847115, .normal),
        (0.9473024010658264, .tool(.createTimer)),
    ]
    let dimension = pipeline.actionability.inputDimension
    let values = try #require(
        Float32ArtifactDecoder.decodeLittleEndian(
            data,
            expectedCount: cases.count * dimension
        )
    )

    for (caseIndex, expected) in cases.enumerated() {
        let start = caseIndex * dimension
        let embedding = Array(values[start..<(start + dimension)])
        let probability: Float
        switch try pipeline.actionability.classify(embedding) {
        case .call(let value), .noCall(let value):
            probability = value
        }
        #expect(abs(probability - expected.probability) < 0.00001)
        #expect(try pipeline.route(embedding) == expected.route)
    }
}

private func makeActionabilityMLP() throws -> NativeToolActionabilityMLP {
    try NativeToolActionabilityMLP(
        inputDimension: 2,
        hiddenUnits: 1,
        threshold: 0.5,
        dense0Weight: [1, 0],
        dense0Bias: [0],
        dense1Weight: [10],
        dense1Bias: -5
    )
}
