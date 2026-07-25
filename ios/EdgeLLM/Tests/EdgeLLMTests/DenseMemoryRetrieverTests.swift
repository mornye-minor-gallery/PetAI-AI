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
  let scope = MemoryScope(userID: "local-user", characterID: "emu")
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

private func makeCandidate(
  id: String,
  sessionID: String,
  scope: MemoryScope,
  vector: [Float]
) -> MemoryEmbeddingCandidate {
  let timestamp = Date(timeIntervalSince1970: 1_721_280_000)
  let observation = MemoryObservation(
    id: id,
    sourceMessageID: "message-\(id)",
    sessionID: sessionID,
    scope: scope,
    occurredAt: timestamp,
    rawText: id,
    labels: [MemoryLabel.preference],
    classifierVersion: "test-v1",
    createdAt: timestamp,
    updatedAt: timestamp
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
