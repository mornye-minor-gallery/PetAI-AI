import Foundation
import Testing

@testable import EdgeLLM

private struct DenseTestEmbedder: TextEmbeddingProviding {
  let modelID = "dense-test-v1"
  let dimension = 3

  func embedQuery(_ text: String) async throws -> [Float] {
    [1, 0, 0]
  }

  func embedDocument(_ text: String) async throws -> [Float] {
    [0, 1, 0]
  }
}

private actor DenseTestCandidateLoader: MemoryEmbeddingCandidateLoading {
  private let candidates: [MemoryEmbeddingCandidate]
  private var requestedScope: MemoryScope?
  private var requestedModelID: String?

  init(candidates: [MemoryEmbeddingCandidate]) {
    self.candidates = candidates
  }

  func embeddingCandidates(
    in scope: MemoryScope,
    modelID: String
  ) async throws -> [MemoryEmbeddingCandidate] {
    requestedScope = scope
    requestedModelID = modelID
    return candidates.filter {
      $0.observation.scope == scope
        && $0.embedding.modelID == modelID
    }
  }

  func request() -> (scope: MemoryScope?, modelID: String?) {
    (requestedScope, requestedModelID)
  }
}

@Test
func denseRetrieverRanksScopedMemoriesAndAppliesExclusions() async throws {
  let scope = MemoryScope(userID: "local-user", characterID: "default-character")
  let loader = DenseTestCandidateLoader(
    candidates: [
      makeCandidate(
        id: "favorite-fruit",
        sessionID: "session-old",
        scope: scope,
        vector: [0.9, 0.1, 0]
      ),
      makeCandidate(
        id: "museum-event",
        sessionID: "session-visible",
        scope: scope,
        vector: [0.3, 0.7, 0]
      ),
      makeCandidate(
        id: "excluded-observation",
        sessionID: "session-visible",
        scope: scope,
        vector: [1, 0, 0]
      ),
      makeCandidate(
        id: "excluded-session",
        sessionID: "session-hidden",
        scope: scope,
        vector: [1, 0, 0]
      ),
      makeCandidate(
        id: "other-character",
        sessionID: "session-visible",
        scope: MemoryScope(
          userID: "local-user",
          characterID: "other"
        ),
        vector: [1, 0, 0]
      ),
    ]
  )
  let retriever = DenseMemoryRetriever(
    candidateLoader: loader,
    embedder: DenseTestEmbedder()
  )

  let results = try await retriever.search(
    MemorySearchRequest(
      scope: scope,
      query: "내가 좋아하는 과일은?",
      topK: 2,
      excludedObservationIDs: ["excluded-observation"],
      excludedSessionIDs: ["session-hidden"]
    )
  )

  #expect(
    results.map(\.observation.id) == [
      "favorite-fruit",
      "museum-event",
    ])
  #expect(results.map(\.rank) == [1, 2])
  #expect(results[0].score > results[1].score)
  let request = await loader.request()
  #expect(request.scope == scope)
  #expect(request.modelID == "dense-test-v1")
}

@Test
func denseRetrieverExcludesTurnsAndDeduplicatesExactRawText() async throws {
  let scope = MemoryScope(userID: "local-user", characterID: "default-character")
  let loader = DenseTestCandidateLoader(
    candidates: [
      makeCandidate(
        id: "duplicate-high",
        sessionID: "session-1",
        scope: scope,
        vector: [1, 0, 0],
        rawText: "나는  딸기를 좋아해"
      ),
      makeCandidate(
        id: "duplicate-low",
        sessionID: "session-2",
        scope: scope,
        vector: [0.9, 0.1, 0],
        rawText: "나는 딸기를 좋아해"
      ),
      makeCandidate(
        id: "excluded-turn",
        sessionID: "session-3",
        scope: scope,
        vector: [1, 0, 0]
      ),
    ]
  )
  let retriever = DenseMemoryRetriever(
    candidateLoader: loader,
    embedder: DenseTestEmbedder()
  )

  let results = try await retriever.search(
    MemorySearchRequest(
      scope: scope,
      query: "좋아하는 과일",
      topK: 3,
      excludedTurnIDs: ["message-excluded-turn"]
    )
  )

  #expect(results.map(\.observation.id) == ["duplicate-high"])
}

@Test
func denseRetrieverFiltersCandidatesBelowMinimumSimilarity() async throws {
  let scope = MemoryScope(userID: "local-user", characterID: "default-character")
  let loader = DenseTestCandidateLoader(
    candidates: [
      makeCandidate(
        id: "above-threshold",
        sessionID: "session-1",
        scope: scope,
        vector: [0.4, 0.6, 0]
      ),
      makeCandidate(
        id: "below-threshold",
        sessionID: "session-2",
        scope: scope,
        vector: [0.2, 0.98, 0]
      ),
    ]
  )
  let retriever = DenseMemoryRetriever(
    candidateLoader: loader,
    embedder: DenseTestEmbedder()
  )

  let results = try await retriever.search(
    MemorySearchRequest(
      scope: scope,
      query: "관련 기억",
      topK: 10,
      minimumSimilarity: 0.3
    )
  )

  #expect(results.map(\.observation.id) == ["above-threshold"])
}

private func makeCandidate(
  id: String,
  sessionID: String,
  scope: MemoryScope,
  vector: [Float],
  rawText: String? = nil
) -> MemoryEmbeddingCandidate {
  let timestamp = Date(timeIntervalSince1970: 1_721_280_000)
  let observation = MemoryObservation(
    id: id,
    turnID: "message-\(id)",
    sessionID: sessionID,
    sequence: 0,
    scope: scope,
    occurredAt: timestamp,
    rawText: rawText ?? id,
    labelEvidence: [
      MemoryLabelEvidence(
        label: .preference,
        score: 0.8,
        source: .prototype,
        classifierVersion: "test-v1"
      )
    ],
    createdAt: timestamp
  )
  return MemoryEmbeddingCandidate(
    observation: observation,
    embedding: MemoryObservationEmbedding(
      observationID: id,
      modelID: "dense-test-v1",
      vector: vector,
      createdAt: timestamp
    )
  )
}
