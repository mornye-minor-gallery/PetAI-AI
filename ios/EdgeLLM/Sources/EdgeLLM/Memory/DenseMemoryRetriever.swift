import Foundation

public enum DenseMemoryRetrieverError: Error, Equatable, Sendable {
  case emptyQuery
  case invalidSearchLimit
  case invalidMinimumSimilarity
  case invalidQueryDimension(expected: Int, actual: Int)
  case nonFiniteQueryEmbedding(index: Int)
}

extension DenseMemoryRetrieverError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .emptyQuery:
      "Dense memory search requires a non-empty query."
    case .invalidSearchLimit:
      "Dense memory search topK must be greater than zero."
    case .invalidMinimumSimilarity:
      "Dense memory search minimum similarity must be finite and between -1 and 1."
    case .invalidQueryDimension(let expected, let actual):
      "Dense memory search expected a \(expected)-value query embedding, but received \(actual)."
    case .nonFiniteQueryEmbedding(let index):
      "Dense memory query embedding contains a non-finite value at index \(index)."
    }
  }
}

public struct DenseMemoryRetriever: MemoryRetrieving {
  private let candidateLoader: any MemoryEmbeddingCandidateLoading
  private let embedder: any TextEmbeddingProviding

  public init(
    candidateLoader: any MemoryEmbeddingCandidateLoading,
    embedder: any TextEmbeddingProviding
  ) {
    self.candidateLoader = candidateLoader
    self.embedder = embedder
  }

  public func search(
    _ request: MemorySearchRequest
  ) async throws -> [RetrievedMemoryObservation] {
    guard request.topK > 0 else {
      throw DenseMemoryRetrieverError.invalidSearchLimit
    }
    guard
      request.minimumSimilarity.isFinite,
      (-1...1).contains(request.minimumSimilarity)
    else {
      throw DenseMemoryRetrieverError.invalidMinimumSimilarity
    }
    let query = request.query.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !query.isEmpty else {
      throw DenseMemoryRetrieverError.emptyQuery
    }

    let queryVector = try await embedder.embedQuery(query)
    guard queryVector.count == embedder.dimension else {
      throw DenseMemoryRetrieverError.invalidQueryDimension(
        expected: embedder.dimension,
        actual: queryVector.count
      )
    }
    if let index = queryVector.firstIndex(where: { !$0.isFinite }) {
      throw DenseMemoryRetrieverError.nonFiniteQueryEmbedding(
        index: index
      )
    }
    let candidates = try await candidateLoader.embeddingCandidates(
      in: request.scope,
      modelID: embedder.modelID
    )

    var scoredCandidates: [ScoredCandidate] = []
    scoredCandidates.reserveCapacity(candidates.count)
    for candidate in candidates
    where
      !request.excludedObservationIDs.contains(
        candidate.observation.id
      )
      && !request.excludedTurnIDs.contains(
        candidate.observation.turnID
      )
      && !request.excludedSessionIDs.contains(
        candidate.observation.sessionID
      )
    {
      let score = try EmbeddingVectorMath.cosineSimilarity(
        queryVector,
        candidate.embedding.vector
      )
      guard score >= request.minimumSimilarity else {
        continue
      }
      scoredCandidates.append(
        ScoredCandidate(
          observation: candidate.observation,
          score: score
        )
      )
    }

    scoredCandidates.sort { left, right in
      if left.score != right.score {
        return left.score > right.score
      }
      if left.observation.occurredAt != right.observation.occurredAt {
        return left.observation.occurredAt
          > right.observation.occurredAt
      }
      return left.observation.id < right.observation.id
    }

    var seenTexts: Set<String> = []
    let deduplicated = scoredCandidates.filter { candidate in
      seenTexts.insert(
        normalizedText(candidate.observation.rawText)
      ).inserted
    }

    return
      deduplicated
      .prefix(request.topK)
      .enumerated()
      .map { index, candidate in
        RetrievedMemoryObservation(
          observation: candidate.observation,
          score: candidate.score,
          rank: index + 1
        )
      }
  }

  private func normalizedText(_ text: String) -> String {
    text
      .precomposedStringWithCompatibilityMapping
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }
}

private struct ScoredCandidate {
  let observation: MemoryObservation
  let score: Float
}
