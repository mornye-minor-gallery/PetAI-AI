import Foundation

#if canImport(EdgeLLM)
import EdgeLLM
#endif

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

actor MemoryService: ChatMemoryService {
  nonisolated let modelID =
    "litert-community/embeddinggemma-300m-seq256-mixed-precision"
  nonisolated let dimension = 768

  private let embedder = EmbeddingGemmaEmbedder()
  private var worldInfoEmbeddingIdentity: String?
  private var worldInfoIndex: WorldInfoVectorIndex?
  private var observationStore: SQLiteObservationStore?
  private var engine: MemoryEngine?
  private var preparationTask: Task<Void, Error>?
  private let supportDirectory: URL?

  init(supportDirectory: URL? = nil) {
    self.supportDirectory = supportDirectory
  }

  private func applicationSupportDirectory() throws -> URL {
    if let supportDirectory { return supportDirectory }
    return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true)
  }

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

  func searchEmbeddingIdentity() throws -> String {
    guard let identity = worldInfoEmbeddingIdentity else { throw MemoryServiceError.notPrepared }
    return identity
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

      let identity = try WorldInfoEmbeddingIdentity.make(modelURL: modelURL, tokenizerURL: tokenizerURL,
        preprocessing: "embeddinggemma-seq256-query-document-v1:768")
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
      worldInfoEmbeddingIdentity = identity
      observationStore = store
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
    _ = try requirePrepared()

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

  func remember(
    _ request: MemoryWriteRequest,
    decision: MemoryGateDecision
  ) async throws -> MemoryRememberResult {
    let engine = try requirePrepared()
    return try await engine.remember(
      request,
      decision: decision
    )
  }

  func recall(
    _ request: MemorySearchRequest
  ) async throws -> [RetrievedMemoryObservation] {
    let engine = try requirePrepared()
    return await engine.recall(request)
  }

  func searchWorldInfo(entries: [WorldInfoEntry], newestMessages: [String], settings: WorldInfoVectorSettings) async throws -> [WorldInfoVectorMatch] {
    _ = try requirePrepared()
    guard let identity = worldInfoEmbeddingIdentity else { throw MemoryServiceError.notPrepared }
    if worldInfoIndex == nil {
      let support = try applicationSupportDirectory()
      worldInfoIndex = try WorldInfoVectorIndex(url: support.appendingPathComponent("PetAI/world-info/\(identity).json"),
                                               embeddingIdentity: identity)
    }
    guard let index = worldInfoIndex else { throw MemoryServiceError.notPrepared }
    return try await index.search(entries: entries, newestMessages: newestMessages, settings: settings,
      embedQuery: { try await self.embedWorldInfoQuery($0) },
      embedDocument: { try await self.embedWorldInfoDocument($0) })
  }

  func embedWorldInfoQuery(_ text: String) async throws -> [Float] {
    _ = try requirePrepared()
    try Task.checkCancellation()
    return try await embedder.embedQuery(text)
  }

  func embedWorldInfoDocument(_ text: String) async throws -> [Float] {
    _ = try requirePrepared()
    try Task.checkCancellation()
    return try await embedder.embedDocument(text)
  }

  func embedClassification(_ text: String) async throws -> [Float] {
    _ = try requirePrepared()
    try Task.checkCancellation()
    let vector = try await embedder.embedClassification(text)
    try Task.checkCancellation()
    return vector
  }

  func activeObservations(
    in scope: MemoryScope
  ) async throws -> [MemoryObservation] {
    let engine = try requirePrepared()
    return try await engine.activeObservations(in: scope)
  }

  /// Data export must work without a downloaded or loaded embedding model.
  func allActiveObservations() async throws -> [MemoryObservation] {
    if let observationStore {
      return try await observationStore.allActiveObservations()
    }
    let store = try makeStore()
    do {
      try await store.initialize()
      let observations = try await store.allActiveObservations()
      await store.close()
      return observations
    } catch {
      await store.close()
      throw error
    }
  }

  func close() async {
    worldInfoIndex = nil
    worldInfoEmbeddingIdentity = nil
    preparationTask?.cancel()
    preparationTask = nil
    let activeEngine = engine
    engine = nil
    await activeEngine?.close()
    observationStore = nil
    await embedder.unload()
  }

  /// Bridge admission is closed and all conversations/captions have drained before this call.
  /// Opening SQLite alone works even when the model has never been downloaded.
  func eraseAllMemories() async throws {
    if let observationStore {
      try await observationStore.eraseAllMemories()
    } else {
      let store = try makeStore()
      do {
        try await store.initialize()
        try await store.eraseAllMemories()
        await store.close()
      } catch {
        await store.close()
        throw error
      }
    }
  }

  private func requirePrepared() throws -> MemoryEngine {
    guard let engine else {
      throw MemoryServiceError.notPrepared
    }
    return engine
  }

  private func makeStore() throws -> SQLiteObservationStore {
    let applicationSupport = try applicationSupportDirectory()
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
