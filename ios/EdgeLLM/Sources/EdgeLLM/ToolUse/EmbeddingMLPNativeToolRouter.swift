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
