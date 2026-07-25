import EdgeLLM
import Foundation

enum MemoryServiceError: Error, Equatable {
  case notPrepared
}

extension MemoryServiceError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .notPrepared:
      "Prepare the memory service first."
    }
  }
}

struct EmbeddingComparison: Sendable {
  let dimension: Int
  let similarScore: Float
  let differentScore: Float
}

actor MemoryService {
  private let embedder = EmbeddingGemmaEmbedder()
  private var engine: MemoryEngine?

  func prepare(
    modelURL: URL,
    tokenizerURL: URL
  ) async throws {
    await close()

    do {
      try await embedder.prepare(
        modelURL: modelURL,
        tokenizerURL: tokenizerURL
      )

      let store = try makeStore()
      let retriever = DenseMemoryRetriever(
        candidateLoader: store,
        embedder: embedder
      )
      let candidate = MemoryEngine(
        store: store,
        embedder: embedder,
        retriever: retriever,
        securityRequirement: .allowsUnencryptedAppPrivatePrototype
      )

      do {
        try await candidate.prepare()
      } catch {
        await candidate.close()
        throw error
      }
      engine = candidate
    } catch {
      await embedder.unload()
      throw error
    }
  }

  func compare(
    query: String,
    similarDocument: String,
    differentDocument: String
  ) async throws -> EmbeddingComparison {
    try requirePrepared()

    let queryVector = try await embedder.embedQuery(query)
    let similarVector = try await embedder.embedDocument(
      similarDocument
    )
    let differentVector = try await embedder.embedDocument(
      differentDocument
    )

    return EmbeddingComparison(
      dimension: queryVector.count,
      similarScore: try EmbeddingVectorMath.cosineSimilarity(
        queryVector,
        similarVector
      ),
      differentScore: try EmbeddingVectorMath.cosineSimilarity(
        queryVector,
        differentVector
      )
    )
  }

  func remember(
    _ request: MemoryWriteRequest
  ) async throws -> MemoryRememberResult {
    let engine = try requirePrepared()
    return try await engine.remember(request)
  }

  func recall(
    _ request: MemorySearchRequest
  ) async throws -> [RetrievedMemoryObservation] {
    let engine = try requirePrepared()
    return await engine.recall(request)
  }

  func activeObservations(
    in scope: MemoryScope
  ) async throws -> [MemoryObservation] {
    let engine = try requirePrepared()
    return try await engine.activeObservations(in: scope)
  }

  func close() async {
    let activeEngine = engine
    engine = nil
    await activeEngine?.close()
    await embedder.unload()
  }

  private func requirePrepared() throws -> MemoryEngine {
    guard let engine else {
      throw MemoryServiceError.notPrepared
    }
    return engine
  }

  private func makeStore() throws -> SQLiteObservationStore {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let databaseURL =
      applicationSupport
      .appendingPathComponent("EdgeLLM", isDirectory: true)
      .appendingPathComponent("Memory", isDirectory: true)
      .appendingPathComponent(
        "edgemem-dense-spike.sqlite3",
        isDirectory: false
      )
    return SQLiteObservationStore(databaseURL: databaseURL)
  }
}
