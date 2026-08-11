import CryptoKit
import Foundation

public protocol NativeToolRouting: Sendable {
    func route(_ utterance: String) async throws -> NativeToolRoute
}

public enum NativeToolRoutingError: Error, Equatable, Sendable {
    case resourceMissing(String)
    case checksumMismatch(
        resource: String,
        expected: String,
        actual: String
    )
    case invalidManifest
    case unsupportedContract(String)
    case invalidWeightPayload
    case invalidPrototypePayload
    case invalidEmbeddingDimension(expected: Int, actual: Int)
    case nonFiniteEmbedding(index: Int)
    case zeroMagnitudeEmbedding
    case embeddingUnavailable
}

extension NativeToolRoutingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .resourceMissing(let resource):
            "Missing native Tool Router resource: \(resource)."
        case .checksumMismatch(let resource, let expected, let actual):
            "Native Tool Router resource \(resource) has SHA-256 \(actual), expected \(expected)."
        case .invalidManifest:
            "The native Tool Router manifest is invalid."
        case .unsupportedContract(let value):
            "Unsupported native Tool Router contract: \(value)."
        case .invalidWeightPayload:
            "The native Tool Router MLP weights are invalid."
        case .invalidPrototypePayload:
            "The native Tool Router prototype vectors are invalid."
        case .invalidEmbeddingDimension(let expected, let actual):
            "Expected a \(expected)-value Tool Router embedding, but received \(actual)."
        case .nonFiniteEmbedding(let index):
            "The Tool Router embedding contains a non-finite value at index \(index)."
        case .zeroMagnitudeEmbedding:
            "The Tool Router embedding has zero magnitude."
        case .embeddingUnavailable:
            "The classification embedding is unavailable for native Tool routing."
        }
    }
}

public enum NativeToolActionability: Equatable, Sendable {
    case noCall(probability: Float)
    case call(probability: Float)
}

public struct NativeToolActionabilityMLP: Sendable {
    public let inputDimension: Int
    public let hiddenUnits: Int
    public let threshold: Float

    private let dense0Weight: [Float]
    private let dense0Bias: [Float]
    private let dense1Weight: [Float]
    private let dense1Bias: Float

    init(
        inputDimension: Int,
        hiddenUnits: Int,
        threshold: Float,
        dense0Weight: [Float],
        dense0Bias: [Float],
        dense1Weight: [Float],
        dense1Bias: Float
    ) throws {
        guard inputDimension > 0,
              hiddenUnits > 0,
              threshold.isFinite,
              threshold > 0,
              threshold < 1,
              dense0Weight.count == inputDimension * hiddenUnits,
              dense0Bias.count == hiddenUnits,
              dense1Weight.count == hiddenUnits,
              dense1Bias.isFinite,
              !dense0Weight.contains(where: { !$0.isFinite }),
              !dense0Bias.contains(where: { !$0.isFinite }),
              !dense1Weight.contains(where: { !$0.isFinite })
        else {
            throw NativeToolRoutingError.invalidWeightPayload
        }
        self.inputDimension = inputDimension
        self.hiddenUnits = hiddenUnits
        self.threshold = threshold
        self.dense0Weight = dense0Weight
        self.dense0Bias = dense0Bias
        self.dense1Weight = dense1Weight
        self.dense1Bias = dense1Bias
    }

    public func classify(_ embedding: [Float]) throws -> NativeToolActionability {
        try validateEmbedding(embedding)

        var logit = dense1Bias
        for hiddenIndex in 0..<hiddenUnits {
            var activation = dense0Bias[hiddenIndex]
            for inputIndex in 0..<inputDimension {
                activation += embedding[inputIndex]
                    * dense0Weight[inputIndex * hiddenUnits + hiddenIndex]
            }
            let relu = max(0, activation)
            logit += relu * dense1Weight[hiddenIndex]
        }
        let probability: Float
        if logit >= 0 {
            probability = Float(1 / (1 + Foundation.exp(Double(-logit))))
        } else {
            let exponent = Foundation.exp(Double(logit))
            probability = Float(exponent / (1 + exponent))
        }
        return probability >= threshold
            ? .call(probability: probability)
            : .noCall(probability: probability)
    }

    private func validateEmbedding(_ embedding: [Float]) throws {
        guard embedding.count == inputDimension else {
            throw NativeToolRoutingError.invalidEmbeddingDimension(
                expected: inputDimension,
                actual: embedding.count
            )
        }
        for (index, value) in embedding.enumerated() {
            guard value.isFinite else {
                throw NativeToolRoutingError.nonFiniteEmbedding(index: index)
            }
        }
    }
}

struct NativeToolEmbeddingRouteDefinition: Sendable {
    let tool: NativeToolKind
    let threshold: Float
    let prototypeOffset: Int
    let prototypeCount: Int
}

public struct NativeToolEmbeddingSelector: Sendable {
    public let dimension: Int
    public let prototypeCount: Int

    private let routes: [NativeToolEmbeddingRouteDefinition]
    private let normalizedPrototypes: [Float]

    init(
        dimension: Int,
        routes: [NativeToolEmbeddingRouteDefinition],
        prototypes: [Float]
    ) throws {
        guard dimension > 0,
              !routes.isEmpty,
              Set(routes.map(\.tool)).count == routes.count
        else {
            throw NativeToolRoutingError.invalidManifest
        }
        var expectedOffset = 0
        for route in routes {
            guard route.prototypeOffset == expectedOffset,
                  route.prototypeCount > 0,
                  route.threshold.isFinite,
                  route.threshold >= -1,
                  route.threshold < 1
            else {
                throw NativeToolRoutingError.invalidManifest
            }
            expectedOffset += route.prototypeCount
        }
        guard prototypes.count == expectedOffset * dimension else {
            throw NativeToolRoutingError.invalidPrototypePayload
        }

        var normalized = [Float](repeating: 0, count: prototypes.count)
        for prototypeIndex in 0..<expectedOffset {
            let start = prototypeIndex * dimension
            var squaredMagnitude = 0.0
            for index in start..<(start + dimension) {
                let value = prototypes[index]
                guard value.isFinite else {
                    throw NativeToolRoutingError.invalidPrototypePayload
                }
                squaredMagnitude += Double(value) * Double(value)
            }
            guard squaredMagnitude > 0 else {
                throw NativeToolRoutingError.invalidPrototypePayload
            }
            let magnitude = sqrt(squaredMagnitude)
            for index in start..<(start + dimension) {
                normalized[index] = Float(Double(prototypes[index]) / magnitude)
            }
        }

        self.dimension = dimension
        prototypeCount = expectedOffset
        self.routes = routes
        normalizedPrototypes = normalized
    }

    public func route(_ embedding: [Float]) throws -> NativeToolRoute {
        guard embedding.count == dimension else {
            throw NativeToolRoutingError.invalidEmbeddingDimension(
                expected: dimension,
                actual: embedding.count
            )
        }
        var querySquaredMagnitude = 0.0
        for (index, value) in embedding.enumerated() {
            guard value.isFinite else {
                throw NativeToolRoutingError.nonFiniteEmbedding(index: index)
            }
            querySquaredMagnitude += Double(value) * Double(value)
        }
        guard querySquaredMagnitude > 0 else {
            throw NativeToolRoutingError.zeroMagnitudeEmbedding
        }
        let queryMagnitude = sqrt(querySquaredMagnitude)

        var accepted = [NativeToolKind]()
        for route in routes {
            var routeScore = -Float.infinity
            for prototypeIndex in route.prototypeOffset..<(
                route.prototypeOffset + route.prototypeCount
            ) {
                let start = prototypeIndex * dimension
                var dotProduct = 0.0
                for queryIndex in 0..<dimension {
                    dotProduct += Double(embedding[queryIndex])
                        * Double(normalizedPrototypes[start + queryIndex])
                }
                routeScore = max(
                    routeScore,
                    Float(min(1, max(-1, dotProduct / queryMagnitude)))
                )
            }
            if routeScore >= route.threshold {
                accepted.append(route.tool)
            }
        }

        switch accepted.count {
        case 0: return .normal
        case 1: return .tool(accepted[0])
        default: return .conflict(accepted)
        }
    }
}

public struct NativeToolRoutingPipeline: Sendable {
    public let artifactID: String
    public let actionability: NativeToolActionabilityMLP
    public let selector: NativeToolEmbeddingSelector

    public init(
        artifactID: String,
        actionability: NativeToolActionabilityMLP,
        selector: NativeToolEmbeddingSelector
    ) {
        self.artifactID = artifactID
        self.actionability = actionability
        self.selector = selector
    }

    public func route(_ embedding: [Float]) throws -> NativeToolRoute {
        switch try actionability.classify(embedding) {
        case .noCall:
            return .normal
        case .call:
            return try selector.route(embedding)
        }
    }
}

public struct EmbeddingMLPNativeToolRouter: NativeToolRouting {
    private let embedder: any ClassificationEmbeddingProviding
    private let pipeline: NativeToolRoutingPipeline

    public init(
        embedder: any ClassificationEmbeddingProviding,
        pipeline: NativeToolRoutingPipeline
    ) {
        precondition(embedder.modelID == NativeToolRouterArtifactRegistry.expectedModelID)
        precondition(embedder.dimension == pipeline.actionability.inputDimension)
        self.embedder = embedder
        self.pipeline = pipeline
    }

    public func route(_ utterance: String) async throws -> NativeToolRoute {
        guard !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .normal
        }
        let embedding: [Float]
        do {
            embedding = try await embedder.embedClassification(utterance)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NativeToolRoutingError.embeddingUnavailable
        }
        return try pipeline.route(embedding)
    }
}

public struct NativeToolRouterArtifactRegistry: Sendable {
    public typealias Loader = @Sendable (_ fileName: String) -> Data?

    public static let expectedModelID =
        "litert-community/embeddinggemma-300m-seq256-mixed-precision"
    public static let expectedClassificationPrefix =
        "task: classification | query: "
    public static let expectedDimension = 768

    private static let manifestFile = "native_tool_router_v1.json"
    private static let manifestSHA256 =
        "9f644ae559062c328476d24f4d77ac9973e00216e54a238358d4c4409cb09f5e"
    private static let schemaVersion = "petai-native-tool-router-v1"
    private static let artifactID = "toolroutebench-two-stage-v1-retrospective"
    private static let expectedHiddenUnits = 64
    private static let expectedPrototypesPerTool = 12

    private let loader: Loader

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public init() {
        loader = Self.bundleLoader
    }

    public func load() throws -> NativeToolRoutingPipeline {
        guard let manifestData = loader(Self.manifestFile) else {
            throw NativeToolRoutingError.resourceMissing(Self.manifestFile)
        }
        try validateChecksum(
            manifestData,
            resource: Self.manifestFile,
            expected: Self.manifestSHA256
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
              manifest.artifactID == Self.artifactID,
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

    private static let bundleLoader: Loader = { fileName in
        let parts = fileName.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let resource = String(parts[0])
        let fileExtension = String(parts[1])

        #if SWIFT_PACKAGE
        let bundles = [Bundle.module]
        #else
        let bundles = [Bundle.main, Bundle(for: NativeToolRouterBundleToken.self)]
        #endif

        for bundle in bundles {
            let candidates = [
                bundle.url(
                    forResource: resource,
                    withExtension: fileExtension,
                    subdirectory: "ToolRouting"
                ),
                bundle.url(
                    forResource: resource,
                    withExtension: fileExtension,
                    subdirectory: "EdgeLLMPrompts"
                ),
                bundle.url(forResource: resource, withExtension: fileExtension),
            ]
            if let url = candidates.compactMap({ $0 }).first,
               let data = try? Data(contentsOf: url)
            {
                return data
            }
        }
        return nil
    }
}

private final class NativeToolRouterBundleToken {}

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
