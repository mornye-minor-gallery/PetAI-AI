import CryptoKit
import Foundation

public enum EmbeddingSceneRouterError: Error, Equatable, Sendable {
    case resourceMissing(String)
    case checksumMismatch(resource: String, expected: String, actual: String)
    case invalidManifest
    case unsupportedContract(String)
    case invalidRoute(String)
    case invalidVectorPayload
    case invalidQueryDimension(expected: Int, actual: Int)
    case nonFiniteQuery(index: Int)
    case zeroMagnitudeQuery
}

extension EmbeddingSceneRouterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .resourceMissing(let resource):
            "Missing embedding scene router resource: \(resource)."
        case .checksumMismatch(let resource, let expected, let actual):
            "Embedding scene router resource \(resource) has SHA-256 \(actual), expected \(expected)."
        case .invalidManifest:
            "The embedding scene router manifest is invalid."
        case .unsupportedContract(let value):
            "Unsupported embedding scene router contract: \(value)."
        case .invalidRoute(let route):
            "The embedding scene router route is invalid: \(route)."
        case .invalidVectorPayload:
            "The embedding scene router vector payload is invalid."
        case .invalidQueryDimension(let expected, let actual):
            "Expected a \(expected)-value scene embedding, but received \(actual)."
        case .nonFiniteQuery(let index):
            "The scene embedding contains a non-finite value at index \(index)."
        case .zeroMagnitudeQuery:
            "The scene embedding has zero magnitude."
        }
    }
}

public enum EmbeddingSceneRoutingReason: String, Equatable, Sendable {
    case acceptedSpecialist
    case belowThreshold
}

public struct EmbeddingSceneRoutingResult: Equatable, Sendable {
    public let scene: PersonaSceneRoute
    public let reason: EmbeddingSceneRoutingReason
    public let score: Float
    public let threshold: Float
    public let normalizedMargin: Float
    public let acceptedRouteCount: Int

    public init(
        scene: PersonaSceneRoute,
        reason: EmbeddingSceneRoutingReason,
        score: Float,
        threshold: Float,
        normalizedMargin: Float,
        acceptedRouteCount: Int
    ) {
        self.scene = scene
        self.reason = reason
        self.score = score
        self.threshold = threshold
        self.normalizedMargin = normalizedMargin
        self.acceptedRouteCount = acceptedRouteCount
    }
}

struct EmbeddingSceneRouteDefinition: Equatable, Sendable {
    let scene: PersonaSceneRoute
    let threshold: Float
    let prototypeOffset: Int
    let prototypeCount: Int
}

public struct EmbeddingSceneRouter: Sendable {
    public static let expectedModelID =
        "litert-community/embeddinggemma-300m-seq256-mixed-precision"
    public static let expectedClassificationPrefix =
        "task: classification | query: "
    public static let expectedDimension = 768

    public let artifactID: String
    public let dimension: Int
    public let prototypeCount: Int

    private let routes: [EmbeddingSceneRouteDefinition]
    private let normalizedPrototypes: [[Float]]

    init(
        artifactID: String,
        dimension: Int,
        routes: [EmbeddingSceneRouteDefinition],
        prototypes: [[Float]]
    ) throws {
        guard dimension > 0, !routes.isEmpty else {
            throw EmbeddingSceneRouterError.invalidManifest
        }
        guard Set(routes.map(\.scene)).count == routes.count,
              !routes.contains(where: { $0.scene == .general })
        else {
            throw EmbeddingSceneRouterError.invalidManifest
        }

        var expectedOffset = 0
        for route in routes {
            guard route.prototypeOffset == expectedOffset,
                  route.prototypeCount > 0,
                  route.threshold.isFinite,
                  route.threshold >= -1,
                  route.threshold < 1
            else {
                throw EmbeddingSceneRouterError.invalidRoute(
                    route.scene.rawValue
                )
            }
            expectedOffset += route.prototypeCount
        }
        guard expectedOffset == prototypes.count else {
            throw EmbeddingSceneRouterError.invalidVectorPayload
        }

        self.artifactID = artifactID
        self.dimension = dimension
        self.prototypeCount = prototypes.count
        self.routes = routes
        normalizedPrototypes = try prototypes.map { vector in
            guard vector.count == dimension else {
                throw EmbeddingSceneRouterError.invalidVectorPayload
            }
            var squaredMagnitude = 0.0
            for value in vector {
                guard value.isFinite else {
                    throw EmbeddingSceneRouterError.invalidVectorPayload
                }
                squaredMagnitude += Double(value) * Double(value)
            }
            guard squaredMagnitude > 0 else {
                throw EmbeddingSceneRouterError.invalidVectorPayload
            }
            let magnitude = sqrt(squaredMagnitude)
            return vector.map { Float(Double($0) / magnitude) }
        }
    }

    public func route(_ query: [Float]) throws -> EmbeddingSceneRoutingResult {
        guard query.count == dimension else {
            throw EmbeddingSceneRouterError.invalidQueryDimension(
                expected: dimension,
                actual: query.count
            )
        }

        var querySquaredMagnitude = 0.0
        for (index, value) in query.enumerated() {
            guard value.isFinite else {
                throw EmbeddingSceneRouterError.nonFiniteQuery(index: index)
            }
            querySquaredMagnitude += Double(value) * Double(value)
        }
        guard querySquaredMagnitude > 0 else {
            throw EmbeddingSceneRouterError.zeroMagnitudeQuery
        }
        let queryMagnitude = sqrt(querySquaredMagnitude)

        var accepted: [(index: Int, route: EmbeddingSceneRouteDefinition, score: Float, margin: Float)] = []
        var bestObserved: (route: EmbeddingSceneRouteDefinition, score: Float)?

        for (routeIndex, route) in routes.enumerated() {
            let range = route.prototypeOffset..<(
                route.prototypeOffset + route.prototypeCount
            )
            var routeScore = -Float.infinity
            for prototypeIndex in range {
                let prototype = normalizedPrototypes[prototypeIndex]
                var dotProduct = 0.0
                for index in query.indices {
                    dotProduct += Double(query[index]) * Double(prototype[index])
                }
                let score = Float(
                    min(1, max(-1, dotProduct / queryMagnitude))
                )
                routeScore = max(routeScore, score)
            }

            if bestObserved == nil || routeScore > bestObserved!.score {
                bestObserved = (route, routeScore)
            }
            if routeScore >= route.threshold {
                let margin = (routeScore - route.threshold) / (1 - route.threshold)
                accepted.append((routeIndex, route, routeScore, margin))
            }
        }

        guard let winner = accepted.max(by: { left, right in
            if left.margin != right.margin {
                return left.margin < right.margin
            }
            if left.score != right.score {
                return left.score < right.score
            }
            return left.index > right.index
        }) else {
            guard let bestObserved else {
                throw EmbeddingSceneRouterError.invalidManifest
            }
            let margin = (bestObserved.score - bestObserved.route.threshold)
                / (1 - bestObserved.route.threshold)
            return EmbeddingSceneRoutingResult(
                scene: .general,
                reason: .belowThreshold,
                score: bestObserved.score,
                threshold: bestObserved.route.threshold,
                normalizedMargin: margin,
                acceptedRouteCount: 0
            )
        }

        return EmbeddingSceneRoutingResult(
            scene: winner.route.scene,
            reason: .acceptedSpecialist,
            score: winner.score,
            threshold: winner.route.threshold,
            normalizedMargin: winner.margin,
            acceptedRouteCount: accepted.count
        )
    }
}

public struct EmbeddingSceneRouterArtifactRegistry: Sendable {
    public typealias Loader = @Sendable (_ fileName: String) -> Data?

    private static let manifestFile = "scene_router_v2.json"
    private static let manifestSHA256 =
        "33c0409a4b19cc3010378c5c308190d9459171bdab0d6d4cd0c371e269ca5ca8"
    private static let schemaVersion = "petai-scene-embedding-router-v1"
    private static let artifactID = "facetroutebench-v2-retrospective"
    private static let expectedPrototypeCount = 228
    private static let expectedPrototypeCountPerRoute = 12

    private let loader: Loader

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public init() {
        loader = Self.bundleLoader
    }

    public func load() throws -> EmbeddingSceneRouter {
        guard let manifestData = loader(Self.manifestFile) else {
            throw EmbeddingSceneRouterError.resourceMissing(Self.manifestFile)
        }
        let manifestHash = Self.sha256(manifestData)
        guard manifestHash == Self.manifestSHA256 else {
            throw EmbeddingSceneRouterError.checksumMismatch(
                resource: Self.manifestFile,
                expected: Self.manifestSHA256,
                actual: manifestHash
            )
        }
        guard let manifest = try? JSONDecoder().decode(
            Manifest.self,
            from: manifestData
        ) else {
            throw EmbeddingSceneRouterError.invalidManifest
        }

        try validateContract(manifest)
        guard let vectorData = loader(manifest.vectors.file) else {
            throw EmbeddingSceneRouterError.resourceMissing(
                manifest.vectors.file
            )
        }
        let actualHash = Self.sha256(vectorData)
        guard actualHash == manifest.vectors.sha256 else {
            throw EmbeddingSceneRouterError.checksumMismatch(
                resource: manifest.vectors.file,
                expected: manifest.vectors.sha256,
                actual: actualHash
            )
        }

        let prototypes = try decodeVectors(
            vectorData,
            dimension: manifest.model.dimension,
            count: manifest.vectors.prototypeCount
        )
        let routes = try manifest.routes.map { route in
            guard let scene = PersonaSceneRoute(rawValue: route.routeID) else {
                throw EmbeddingSceneRouterError.invalidRoute(route.routeID)
            }
            return EmbeddingSceneRouteDefinition(
                scene: scene,
                threshold: route.threshold,
                prototypeOffset: route.prototypeOffset,
                prototypeCount: route.prototypeCount
            )
        }
        return try EmbeddingSceneRouter(
            artifactID: manifest.artifactID,
            dimension: manifest.model.dimension,
            routes: routes,
            prototypes: prototypes
        )
    }

    private func validateContract(_ manifest: Manifest) throws {
        guard manifest.schemaVersion == Self.schemaVersion,
              manifest.artifactID == Self.artifactID,
              manifest.model.id == EmbeddingSceneRouter.expectedModelID,
              manifest.model.classificationPrefix
                == EmbeddingSceneRouter.expectedClassificationPrefix,
              manifest.model.dimension == EmbeddingSceneRouter.expectedDimension,
              manifest.decision.similarity == "cosine",
              manifest.decision.prototypeAggregation == "max_similarity",
              manifest.decision.arbitration == "normalized_margin",
              manifest.decision.defaultRoute == PersonaSceneRoute.general.rawValue,
              manifest.decision.tieBreak
                == "normalized_margin_then_score_then_route_order",
              manifest.vectors.encoding == "float32_little_endian",
              manifest.vectors.prototypeCount == Self.expectedPrototypeCount
        else {
            throw EmbeddingSceneRouterError.unsupportedContract(
                manifest.schemaVersion
            )
        }

        let expectedRoutes = PersonaSceneRoute.allCases
            .filter { $0 != .general }
            .map(\.rawValue)
        guard manifest.routeOrder == expectedRoutes,
              manifest.routes.map(\.routeID) == expectedRoutes,
              manifest.routes.allSatisfy({
                  $0.prototypeCount == Self.expectedPrototypeCountPerRoute
              })
        else {
            throw EmbeddingSceneRouterError.invalidManifest
        }
    }

    private func decodeVectors(
        _ data: Data,
        dimension: Int,
        count: Int
    ) throws -> [[Float]] {
        guard let values = Float32ArtifactDecoder.decodeLittleEndian(
            data,
            expectedCount: dimension * count
        ) else {
            throw EmbeddingSceneRouterError.invalidVectorPayload
        }

        return stride(from: 0, to: values.count, by: dimension).map { offset in
            Array(values[offset..<(offset + dimension)])
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
        let bundles = [Bundle.main, Bundle(for: EmbeddingSceneRouterBundleToken.self)]
        #endif

        for bundle in bundles {
            let candidates = [
                bundle.url(
                    forResource: resource,
                    withExtension: fileExtension,
                    subdirectory: "SceneRouting"
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

private final class EmbeddingSceneRouterBundleToken {}

private struct Manifest: Decodable {
    let schemaVersion: String
    let artifactID: String
    let model: Model
    let decision: Decision
    let vectors: Vectors
    let routeOrder: [String]
    let routes: [Route]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactID = "artifact_id"
        case model
        case decision
        case vectors
        case routeOrder = "route_order"
        case routes
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

    struct Decision: Decodable {
        let similarity: String
        let prototypeAggregation: String
        let arbitration: String
        let defaultRoute: String
        let tieBreak: String

        enum CodingKeys: String, CodingKey {
            case similarity
            case prototypeAggregation = "prototype_aggregation"
            case arbitration
            case defaultRoute = "default_route"
            case tieBreak = "tie_break"
        }
    }

    struct Vectors: Decodable {
        let file: String
        let encoding: String
        let prototypeCount: Int
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case file
            case encoding
            case prototypeCount = "prototype_count"
            case sha256
        }
    }

    struct Route: Decodable {
        let routeID: String
        let threshold: Float
        let prototypeOffset: Int
        let prototypeCount: Int

        enum CodingKeys: String, CodingKey {
            case routeID = "route_id"
            case threshold
            case prototypeOffset = "prototype_offset"
            case prototypeCount = "prototype_count"
        }
    }
}
