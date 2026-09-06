import CryptoKit
import Foundation
import Testing

@testable import EdgeLLM

@Test
func externalArtifactLoadsAndMatchesAnalyticalProbabilities() throws {
    let fixture = try makeOwnedRouterFixture()
    let pipeline = try NativeToolRouterArtifactRegistry(
        manifestSHA256: fixture.digest,
        loader: { fixture.files[$0] }
    ).load()
    #expect(pipeline.artifactID == "synthetic-contract-test")
    #expect(pipeline.actionability.inputDimension == 768)
    #expect(pipeline.selector.prototypeCount == 84)
    // Hand-authored weights implement sigmoid(10 * relu(x[0]) - 5).
    // No learned weights, source utterances or model embeddings are required.
    for (first, expected) in [(Float(1), Float(0.9933071491)), (0, 0.0066928509)] {
        var embedding = [Float](repeating: 0, count: 768)
        embedding[0] = first
        let actual: Float
        switch try pipeline.actionability.classify(embedding) {
        case .call(let value), .noCall(let value): actual = value
        }
        #expect(abs(actual - expected) < 0.00001)
        #expect(try pipeline.route(embedding) == (first == 1 ? .tool(.getStepCount) : .normal))
    }
}

@Test
func externalArtifactRejectsMissingAndCorruptedWeights() throws {
    let fixture = try makeOwnedRouterFixture()
    let missing = NativeToolRouterArtifactRegistry(manifestSHA256: fixture.digest) {
        $0 == "weights.f32" ? nil : fixture.files[$0]
    }
    #expect(throws: NativeToolRoutingError.resourceMissing("weights.f32")) {
        _ = try missing.load()
    }
    let corrupted = NativeToolRouterArtifactRegistry(manifestSHA256: fixture.digest) {
        $0 == "weights.f32" ? Data([0]) : fixture.files[$0]
    }
    #expect(throws: NativeToolRoutingError.self) { _ = try corrupted.load() }
}

@Test
func externalArtifactRejectsUnsupportedModelContract() throws {
    let fixture = try makeOwnedRouterFixture(modelID: "unsupported-model")
    let registry = NativeToolRouterArtifactRegistry(
        manifestSHA256: fixture.digest,
        loader: { fixture.files[$0] }
    )
    #expect(throws: NativeToolRoutingError.self) { _ = try registry.load() }
}

private struct OwnedRouterFixture: Sendable {
    let files: [String: Data]
    let digest: String
}

private func makeOwnedRouterFixture(
    modelID: String = NativeToolRouterArtifactRegistry.expectedModelID
) throws -> OwnedRouterFixture {
    let dimension = 768
    let hidden = 64
    var weights = [Float](repeating: 0, count: dimension * hidden + hidden * 2 + 1)
    weights[0] = 1
    weights[dimension * hidden + hidden] = 10
    weights[weights.count - 1] = -5
    let tools = NativeToolKind.allCases
    var prototypes = [Float](repeating: 0, count: tools.count * 12 * dimension)
    for tool in tools.indices {
        for prototype in 0..<12 {
            prototypes[(tool * 12 + prototype) * dimension + tool] = 1
        }
    }
    let weightData = floatData(weights)
    let prototypeData = floatData(prototypes)
    let manifest: [String: Any] = [
        "schema_version": "petai-native-tool-router-v1",
        "artifact_id": "synthetic-contract-test",
        "model": [
            "id": modelID,
            "classification_prefix": NativeToolRouterArtifactRegistry.expectedClassificationPrefix,
            "dimension": dimension,
        ],
        "actionability": [
            "architecture": "dense_relu_dense_sigmoid", "hidden_units": hidden,
            "threshold": 0.5,
            "weights": [
                "file": "weights.f32", "sha256": digest(weightData),
                "encoding": "float32_little_endian", "value_count": weights.count,
                "layout": ["dense_0_weight_row_major", "dense_0_bias", "dense_1_weight_row_major", "dense_1_bias"],
            ],
        ],
        "tool_selection": [
            "candidate_id": "embedding-09", "similarity": "cosine",
            "prototype_aggregation": "max_similarity", "decision": "absolute_tool_threshold",
            "conflict": "all_routes_above_threshold",
            "vectors": [
                "file": "prototypes.f32", "sha256": digest(prototypeData),
                "encoding": "float32_little_endian", "prototype_count": tools.count * 12,
            ],
            "tool_order": tools.map(\.rawValue),
            "routes": tools.enumerated().map { index, tool in
                ["tool_id": tool.rawValue, "threshold": 0.8,
                 "prototype_offset": index * 12, "prototype_count": 12] as [String: Any]
            },
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    return OwnedRouterFixture(
        files: ["native_tool_router_v1.json": data, "weights.f32": weightData, "prototypes.f32": prototypeData],
        digest: digest(data)
    )
}

private func floatData(_ values: [Float]) -> Data {
    var data = Data()
    for value in values {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
