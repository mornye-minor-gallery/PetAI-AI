import CryptoKit
import Foundation

public struct NativeToolRouterArtifactRegistry: Sendable {
    public typealias Loader = @Sendable (_ fileName: String) -> Data?

    public static let expectedModelID =
        "litert-community/embeddinggemma-300m-seq256-mixed-precision"
    public static let expectedClassificationPrefix =
        "task: classification | query: "
    public static let expectedDimension = 768

    private static let manifestFile = "native_tool_router_v1.json"
    private static let schemaVersion = "petai-native-tool-router-v1"
    private static let expectedHiddenUnits = 64
    private static let expectedPrototypesPerTool = 12

    private let loader: Loader
    private let manifestSHA256: String

    /// The caller pins an independently approved artifact and supplies its files.
    /// Training data permissions vary, so this package does not ship learned Tool Router weights.
    public init(manifestSHA256: String, loader: @escaping Loader) {
        self.manifestSHA256 = manifestSHA256
        self.loader = loader
    }

    public func load() throws -> NativeToolRoutingPipeline {
        guard let manifestData = loader(Self.manifestFile) else {
            throw NativeToolRoutingError.resourceMissing(Self.manifestFile)
        }
        try validateChecksum(
            manifestData,
            resource: Self.manifestFile,
            expected: manifestSHA256
        )
        guard let manifest = try? JSONDecoder().decode(
            Manifest.self,
            from: manifestData
        ) else {
            throw NativeToolRoutingError.invalidManifest
        }
        try validateContract(manifest)

        guard let weightsData = loader(manifest.actionability.weights.file) else {
            throw NativeToolRoutingError.resourceMissing(
                manifest.actionability.weights.file
            )
        }
        try validateChecksum(
            weightsData,
            resource: manifest.actionability.weights.file,
            expected: manifest.actionability.weights.sha256
        )
        guard let weights = Float32ArtifactDecoder.decodeLittleEndian(
            weightsData,
            expectedCount: manifest.actionability.weights.valueCount
        ) else {
            throw NativeToolRoutingError.invalidWeightPayload
        }

        let inputDimension = manifest.model.dimension
        let hiddenUnits = manifest.actionability.hiddenUnits
        let dense0Count = inputDimension * hiddenUnits
        let expectedWeightCount = dense0Count + hiddenUnits + hiddenUnits + 1
        guard weights.count == expectedWeightCount else {
            throw NativeToolRoutingError.invalidWeightPayload
        }
        let dense0BiasStart = dense0Count
        let dense1WeightStart = dense0BiasStart + hiddenUnits
        let dense1BiasIndex = dense1WeightStart + hiddenUnits
        let actionability = try NativeToolActionabilityMLP(
            inputDimension: inputDimension,
            hiddenUnits: hiddenUnits,
            threshold: manifest.actionability.threshold,
            dense0Weight: Array(weights[0..<dense0Count]),
            dense0Bias: Array(
                weights[dense0BiasStart..<dense1WeightStart]
            ),
            dense1Weight: Array(
                weights[dense1WeightStart..<dense1BiasIndex]
            ),
            dense1Bias: weights[dense1BiasIndex]
        )

        guard let prototypeData = loader(
            manifest.toolSelection.vectors.file
        ) else {
            throw NativeToolRoutingError.resourceMissing(
                manifest.toolSelection.vectors.file
            )
        }
        try validateChecksum(
            prototypeData,
            resource: manifest.toolSelection.vectors.file,
            expected: manifest.toolSelection.vectors.sha256
        )
        let prototypeValueCount = manifest.toolSelection.vectors.prototypeCount
            * inputDimension
        guard let prototypes = Float32ArtifactDecoder.decodeLittleEndian(
            prototypeData,
            expectedCount: prototypeValueCount
        ) else {
            throw NativeToolRoutingError.invalidPrototypePayload
        }
        let routeDefinitions = try manifest.toolSelection.routes.map { route in
            guard let tool = NativeToolKind(rawValue: route.toolID) else {
                throw NativeToolRoutingError.invalidManifest
            }
            return NativeToolEmbeddingRouteDefinition(
                tool: tool,
                threshold: route.threshold,
                prototypeOffset: route.prototypeOffset,
                prototypeCount: route.prototypeCount
            )
        }
        let selector = try NativeToolEmbeddingSelector(
            dimension: inputDimension,
            routes: routeDefinitions,
            prototypes: prototypes
        )
        return NativeToolRoutingPipeline(
            artifactID: manifest.artifactID,
            actionability: actionability,
            selector: selector
        )
    }

    private func validateContract(_ manifest: Manifest) throws {
        let expectedTools = NativeToolKind.allCases.map(\.rawValue)
        guard manifest.schemaVersion == Self.schemaVersion,
              !manifest.artifactID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.model.id == Self.expectedModelID,
              manifest.model.classificationPrefix
                == Self.expectedClassificationPrefix,
              manifest.model.dimension == Self.expectedDimension,
              manifest.actionability.architecture
                == "dense_relu_dense_sigmoid",
              manifest.actionability.hiddenUnits == Self.expectedHiddenUnits,
              manifest.actionability.weights.encoding
                == "float32_little_endian",
              manifest.actionability.weights.layout == [
                  "dense_0_weight_row_major",
                  "dense_0_bias",
                  "dense_1_weight_row_major",
                  "dense_1_bias",
              ],
              manifest.toolSelection.candidateID == "embedding-09",
              manifest.toolSelection.similarity == "cosine",
              manifest.toolSelection.prototypeAggregation
                == "max_similarity",
              manifest.toolSelection.decision
                == "absolute_tool_threshold",
              manifest.toolSelection.conflict
                == "all_routes_above_threshold",
              manifest.toolSelection.vectors.encoding
                == "float32_little_endian",
              manifest.toolSelection.toolOrder == expectedTools,
              manifest.toolSelection.routes.map(\.toolID) == expectedTools,
              manifest.toolSelection.routes.allSatisfy({
                  $0.prototypeCount == Self.expectedPrototypesPerTool
              })
        else {
            throw NativeToolRoutingError.unsupportedContract(
                manifest.schemaVersion
            )
        }
    }

    private func validateChecksum(
        _ data: Data,
        resource: String,
        expected: String
    ) throws {
        let actual = Self.sha256(data)
        guard actual == expected else {
            throw NativeToolRoutingError.checksumMismatch(
                resource: resource,
                expected: expected,
                actual: actual
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

}

private struct Manifest: Decodable {
    let schemaVersion: String
    let artifactID: String
    let model: Model
    let actionability: Actionability
    let toolSelection: ToolSelection

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactID = "artifact_id"
        case model
        case actionability
        case toolSelection = "tool_selection"
    }

    struct Model: Decodable {
        let id: String
        let classificationPrefix: String
        let dimension: Int

        enum CodingKeys: String, CodingKey {
            case id
            case classificationPrefix = "classification_prefix"
            case dimension
        }
    }

    struct Actionability: Decodable {
        let architecture: String
        let hiddenUnits: Int
        let threshold: Float
        let weights: Weights

        enum CodingKeys: String, CodingKey {
            case architecture
            case hiddenUnits = "hidden_units"
            case threshold
            case weights
        }

        struct Weights: Decodable {
            let file: String
            let sha256: String
            let encoding: String
            let layout: [String]
            let valueCount: Int

            enum CodingKeys: String, CodingKey {
                case file
                case sha256
                case encoding
                case layout
                case valueCount = "value_count"
            }
        }
    }

    struct ToolSelection: Decodable {
        let candidateID: String
        let similarity: String
        let prototypeAggregation: String
        let decision: String
        let conflict: String
        let vectors: Vectors
        let toolOrder: [String]
        let routes: [Route]

        enum CodingKeys: String, CodingKey {
            case candidateID = "candidate_id"
            case similarity
            case prototypeAggregation = "prototype_aggregation"
            case decision
            case conflict
            case vectors
            case toolOrder = "tool_order"
            case routes
        }

        struct Vectors: Decodable {
            let file: String
            let sha256: String
            let encoding: String
            let prototypeCount: Int

            enum CodingKeys: String, CodingKey {
                case file
                case sha256
                case encoding
                case prototypeCount = "prototype_count"
            }
        }

        struct Route: Decodable {
            let toolID: String
            let threshold: Float
            let prototypeOffset: Int
            let prototypeCount: Int

            enum CodingKeys: String, CodingKey {
                case toolID = "tool_id"
                case threshold
                case prototypeOffset = "prototype_offset"
                case prototypeCount = "prototype_count"
            }
        }
    }
}
