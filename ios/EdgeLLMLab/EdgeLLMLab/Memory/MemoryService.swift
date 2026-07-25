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
  private var preparationTask: Task<Void, Error>?

  func prepare(
    modelURL: URL,
    tokenizerURL: URL
  ) async throws {
    await close()
    try await prepareIfNeeded(
      modelURL: modelURL,
      tokenizerURL: tokenizerURL
    )
  }

  func prepareIfNeeded(
    modelURL: URL,
    tokenizerURL: URL
  ) async throws {
    if engine != nil {
      return
    }
    if let preparationTask {
      try await preparationTask.value
      return
    }

    let task = Task {
      try await prepareComponents(
        modelURL: modelURL,
        tokenizerURL: tokenizerURL
      )
    }
    preparationTask = task

    do {
      try await task.value
      preparationTask = nil
    } catch {
      preparationTask = nil
      throw error
    }
  }

  func isPrepared() -> Bool {
    engine != nil
  }

  private func prepareComponents(
    modelURL: URL,
    tokenizerURL: URL
  ) async throws {
    do {
      try await embedder.prepare(
        modelURL: modelURL,
        tokenizerURL: tokenizerURL
      )
      try Task.checkCancellation()

      let store = try makeStore()
      let retriever = DenseMemoryRetriever(
        candidateLoader: store,
        embedder: embedder
      )
      let classifier = RegexPrototypeObservationClassifier(
        embedder: embedder,
        prototypes: try MemoryPrototypeSet.korean()
      )
      let candidate = MemoryEngine(
        store: store,
        classifier: classifier,
        embedder: embedder,
        retriever: retriever,
        securityRequirement: .allowsUnencryptedAppPrivatePrototype
      )

      do {
        try await candidate.prepare()
        try Task.checkCancellation()
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
    preparationTask?.cancel()
    preparationTask = nil
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
      .appendingPathComponent("edgemem.sqlite3", isDirectory: false)
    let legacyDatabaseURL =
      databaseURL
      .deletingLastPathComponent()
      .appendingPathComponent(
        "edgemem-dense-spike.sqlite3",
        isDirectory: false
      )
    try SQLiteObservationStore.removeDatabase(at: legacyDatabaseURL)
    return SQLiteObservationStore(databaseURL: databaseURL)
  }
}
