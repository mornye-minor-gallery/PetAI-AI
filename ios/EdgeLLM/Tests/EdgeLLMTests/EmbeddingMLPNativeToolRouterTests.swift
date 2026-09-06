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
    let registry = NativeToolRouterArtifactRegistry(manifestSHA256: String(repeating: "0", count: 64)) { fileName in
        fileName == "native_tool_router_v1.json" ? Data("{}".utf8) : nil
    }

    #expect(throws: NativeToolRoutingError.self) {
        _ = try registry.load()
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
