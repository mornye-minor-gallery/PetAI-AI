import Foundation

public enum EmbeddingSceneRouterError: Error, Equatable, Sendable {
    case invalidManifest
    case invalidRoute(String)
    case invalidVectorPayload
    case invalidQueryDimension(expected: Int, actual: Int)
    case nonFiniteQuery(index: Int)
    case zeroMagnitudeQuery
}

extension EmbeddingSceneRouterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "The embedding scene router manifest is invalid."
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
