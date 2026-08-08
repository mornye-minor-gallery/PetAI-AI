import Foundation
import Testing

@testable import EdgeLLM

@Test
func embeddingSceneRouterRegistryLoadsFrozenV2Artifact() throws {
    let router = try EmbeddingSceneRouterArtifactRegistry().load()

    #expect(router.artifactID == "facetroutebench-v2-retrospective")
    #expect(router.dimension == 768)
    #expect(router.prototypeCount == 228)
}

@Test
func embeddingSceneRouterUsesPerRouteThresholds() throws {
    let router = try makeRouter(
        thresholds: [0.8, 0.6],
        prototypes: [[1, 0], [0, 1]]
    )

    #expect(try router.route([0.99, 0.1]).scene == .firstSignal)
    #expect(try router.route([1, 1]).scene == .earthTerm)
}

@Test
func embeddingSceneRouterDefaultsToGeneralBelowEveryThreshold() throws {
    let router = try makeRouter(
        thresholds: [0.9, 0.9],
        prototypes: [[1, 0], [0, 1]]
    )

    let result = try router.route([1, 1])

    #expect(result.scene == .general)
    #expect(result.reason == .belowThreshold)
    #expect(result.acceptedRouteCount == 0)
}

@Test
func embeddingSceneRouterArbitratesWithNormalizedMargin() throws {
    let router = try makeRouter(
        thresholds: [0.8, 0.5],
        prototypes: [
            [0.9, Float(sqrt(0.19))],
            [0.8, 0.6],
        ]
    )

    let result = try router.route([1, 0])

    #expect(result.scene == .earthTerm)
    #expect(result.acceptedRouteCount == 2)
    #expect(result.score < 0.81)
}

@Test
func embeddingSceneRouterBreaksExactTiesByRouteOrder() throws {
    let router = try makeRouter(
        thresholds: [0.5, 0.5],
        prototypes: [[1, 0], [1, 0]]
    )

    #expect(try router.route([1, 0]).scene == .firstSignal)
}

@Test
func embeddingSceneRouterRejectsInvalidQueryVectors() throws {
    let router = try makeRouter(
        thresholds: [0.5, 0.5],
        prototypes: [[1, 0], [0, 1]]
    )

    #expect(throws: EmbeddingSceneRouterError.invalidQueryDimension(
        expected: 2,
        actual: 1
    )) {
        _ = try router.route([1])
    }
    #expect(throws: EmbeddingSceneRouterError.nonFiniteQuery(index: 1)) {
        _ = try router.route([1, .nan])
    }
    #expect(throws: EmbeddingSceneRouterError.zeroMagnitudeQuery) {
        _ = try router.route([0, 0])
    }
}

@Test
func embeddingSceneRouterRegistryRejectsMalformedManifest() {
    let registry = EmbeddingSceneRouterArtifactRegistry { fileName in
        fileName == "scene_router_v2.json" ? Data("{}".utf8) : nil
    }

    #expect(throws: EmbeddingSceneRouterError.self) {
        _ = try registry.load()
    }
}

private func makeRouter(
    thresholds: [Float],
    prototypes: [[Float]]
) throws -> EmbeddingSceneRouter {
    #expect(thresholds.count == 2)
    #expect(prototypes.count == 2)
    return try EmbeddingSceneRouter(
        artifactID: "test",
        dimension: 2,
        routes: [
            EmbeddingSceneRouteDefinition(
                scene: .firstSignal,
                threshold: thresholds[0],
                prototypeOffset: 0,
                prototypeCount: 1
            ),
            EmbeddingSceneRouteDefinition(
                scene: .earthTerm,
                threshold: thresholds[1],
                prototypeOffset: 1,
                prototypeCount: 1
            ),
        ],
        prototypes: prototypes
    )
}
