import EdgeLLM
import SwiftUI
import UniformTypeIdentifiers

struct EmbeddingTestView: View {
  let memoryService: MemoryService

  @State private var assetStore = EmbeddingAssetStore()
  @State private var importKind: EmbeddingAssetKind?
  @State private var isImporterPresented = false
  @State private var modelURL: URL?
  @State private var tokenizerURL: URL?
  @State private var status = "Model and tokenizer required"
  @State private var isWorking = false
  @State private var isReady = false
  @State private var query =
    "나는 딸기를 좋아한다."
  @State private var similarDocument =
    "내가 좋아하는 과일은 딸기다."
  @State private var differentDocument =
    "오늘은 비가 많이 내린다."
  @State private var similarScore: Float?
  @State private var differentScore: Float?
  @State private var vectorDimension: Int?
  @State private var elapsedSeconds: TimeInterval?
  @State private var memoryQuery =
    "내가 좋아하는 과일이 뭐였지?"
  @State private var memoryStatus =
    "Prepare the embedding runtime first"
  @State private var memoryResults: [RetrievedMemoryObservation] = []
  @State private var memoryElapsedSeconds: TimeInterval?

  var body: some View {
    NavigationStack {
      Form {
        runtimeSection
        sentenceSection
        resultSection
        memoryRetrievalSection
      }
      .navigationTitle("Embedding Test")
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: allowedContentTypes,
      allowsMultipleSelection: false
    ) { result in
      handleImport(result)
    }
    .task {
      await restoreInstalledAssets()
    }
  }

  private var runtimeSection: some View {
    Section("CPU Runtime") {
      LabeledContent("Status", value: status)
      LabeledContent(
        "Model",
        value: modelURL?.lastPathComponent ?? "Not installed"
      )
      LabeledContent(
        "Tokenizer",
        value: tokenizerURL?.lastPathComponent ?? "Not installed"
      )

      Button("Import .tflite model") {
        presentImporter(for: .model)
      }
      .disabled(isWorking)

      Button("Import sentencepiece.model") {
        presentImporter(for: .tokenizer)
      }
      .disabled(isWorking)

      Button("Prepare CPU runtime") {
        prepareRuntime()
      }
      .disabled(
        isWorking || modelURL == nil || tokenizerURL == nil
      )
    }
  }

  private var sentenceSection: some View {
    Section("Search Example") {
      TextField("Query", text: $query, axis: .vertical)
      TextField(
        "Similar document",
        text: $similarDocument,
        axis: .vertical
      )
      TextField(
        "Different document",
        text: $differentDocument,
        axis: .vertical
      )

      Button("Run embedding test") {
        runTest()
      }
      .disabled(isWorking || !isReady)
    }
  }

  private var resultSection: some View {
    Section("Result") {
      LabeledContent(
        "Vector",
        value: vectorDimension.map { "\($0) values" } ?? "Not run"
      )
      LabeledContent(
        "Query ↔ similar",
        value: formattedScore(similarScore)
      )
      LabeledContent(
        "Query ↔ different",
        value: formattedScore(differentScore)
      )
      LabeledContent(
        "Elapsed",
        value: elapsedSeconds.map {
          "\($0.formatted(.number.precision(.fractionLength(3))))s"
        } ?? "Not run"
      )

      if let similarScore, let differentScore {
        Text(
          similarScore > differentScore
            ? "Pass: the related sentence ranked higher."
            : "Check: the unrelated sentence ranked as high or higher."
        )
        .foregroundStyle(
          similarScore > differentScore ? .green : .orange
        )
      }
    }
  }

  private var memoryRetrievalSection: some View {
    Section("Memory Retrieval Test") {
      TextField(
        "Memory query",
        text: $memoryQuery,
        axis: .vertical
      )

      Button("Store and retrieve memories") {
        runMemoryRetrievalTest()
      }
      .disabled(isWorking || !isReady)

      LabeledContent("Status", value: memoryStatus)
      LabeledContent(
        "Elapsed",
        value: memoryElapsedSeconds.map {
          "\($0.formatted(.number.precision(.fractionLength(3))))s"
        } ?? "Not run"
      )

      ForEach(memoryResults, id: \.observation.id) { result in
        VStack(alignment: .leading, spacing: 4) {
          Text("#\(result.rank) · \(formattedScore(result.score))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          Text(result.observation.rawText)
        }
      }

      Text(
        "Debug scope: local-user / emu. This prototype database is app-private and excluded from backup, but it is not encrypted yet."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var allowedContentTypes: [UTType] {
    switch importKind {
    case .model:
      [UTType(filenameExtension: "tflite") ?? .data]
    case .tokenizer:
      [UTType(filenameExtension: "model") ?? .data]
    case nil:
      [.data]
    }
  }

  private func presentImporter(for kind: EmbeddingAssetKind) {
    importKind = kind
    isImporterPresented = true
  }

  private func handleImport(_ result: Result<[URL], Error>) {
    guard let kind = importKind else {
      status = "No asset type was selected"
      return
    }

    switch result {
    case .success(let URLs):
      guard let selectedURL = URLs.first else {
        status = "No file selected"
        return
      }
      importAsset(selectedURL, kind: kind)
    case .failure(let error):
      status = error.localizedDescription
    }
  }

  private func importAsset(
    _ sourceURL: URL,
    kind: EmbeddingAssetKind
  ) {
    isWorking = true
    isReady = false
    status = "Copying \(kind.displayName)"
    memoryStatus = "Prepare the embedding runtime first"
    memoryResults = []
    memoryElapsedSeconds = nil
    clearResults()

    Task {
      do {
        await memoryService.close()
        let installedURL = try await assetStore.importAsset(
          from: sourceURL,
          kind: kind
        )
        switch kind {
        case .model:
          modelURL = installedURL
        case .tokenizer:
          tokenizerURL = installedURL
        }
        status = "\(kind.displayName) installed"
      } catch {
        status = error.localizedDescription
      }
      isWorking = false
    }
  }

  private func restoreInstalledAssets() async {
    do {
      let installed = try await assetStore.installedAssets()
      modelURL = installed.modelURL
      tokenizerURL = installed.tokenizerURL
      if modelURL != nil, tokenizerURL != nil {
        status = "Assets installed · prepare runtime"
      }
    } catch {
      status = error.localizedDescription
    }
  }

  private func prepareRuntime() {
    guard let modelURL, let tokenizerURL else {
      status = "Model and tokenizer required"
      return
    }

    isWorking = true
    isReady = false
    status = "Preparing CPU runtime"
    clearResults()

    Task {
      do {
        try await memoryService.prepare(
          modelURL: modelURL,
          tokenizerURL: tokenizerURL
        )
        isReady = true
        status = "Ready · CPU"
        memoryStatus = "Ready for SQLite dense retrieval"
      } catch {
        status = error.localizedDescription
        memoryStatus = "Embedding runtime is not ready"
      }
      isWorking = false
    }
  }

  private func runTest() {
    isWorking = true
    status = "Embedding three sentences"
    clearResults()

    Task {
      let startedAt = Date()
      do {
        let comparison = try await memoryService.compare(
          query: query,
          similarDocument: similarDocument,
          differentDocument: differentDocument
        )

        vectorDimension = comparison.dimension
        similarScore = comparison.similarScore
        differentScore = comparison.differentScore
        elapsedSeconds = Date().timeIntervalSince(startedAt)
        status = "Complete · CPU"
      } catch {
        status = error.localizedDescription
      }
      isWorking = false
    }
  }

  private func runMemoryRetrievalTest() {
    isWorking = true
    memoryStatus = "Preparing isolated SQLite memory"
    memoryResults = []
    memoryElapsedSeconds = nil

    Task {
      let startedAt = Date()
      do {
        let output = try await performMemoryRetrieval()
        memoryResults = output.results
        memoryElapsedSeconds = Date().timeIntervalSince(startedAt)
        memoryStatus =
          "Complete · \(output.storedCount) stored memories"
      } catch {
        memoryStatus = error.localizedDescription
      }
      isWorking = false
    }
  }

  private func performMemoryRetrieval() async throws -> MemoryRunOutput {
    let scope = MemoryScope(
      userID: "local-user",
      characterID: "emu"
    )
    try await seedMissingMemories(in: scope)
    let storedCount = try await memoryService.activeObservations(
      in: scope
    ).count
    let results = try await memoryService.recall(
      MemorySearchRequest(
        scope: scope,
        query: memoryQuery,
        topK: 3
      )
    )
    return MemoryRunOutput(
      storedCount: storedCount,
      results: results
    )
  }

  private func seedMissingMemories(
    in scope: MemoryScope
  ) async throws {
    let existingSourceIDs = Set(
      try await memoryService.activeObservations(in: scope)
        .map(\.sourceMessageID)
    )
    let seeds = [
      MemorySeed(
        sourceMessageID: "dense-spike-preference-1",
        rawText: "나는 딸기를 좋아해."
      ),
      MemorySeed(
        sourceMessageID: "dense-spike-event-1",
        rawText: "어제 에무와 함께 미술관에 다녀왔어."
      ),
    ]

    for seed in seeds
    where !existingSourceIDs.contains(seed.sourceMessageID) {
      _ = try await memoryService.remember(
        MemoryWriteRequest(
          sourceMessageID: seed.sourceMessageID,
          sessionID: "dense-spike-seed",
          scope: scope,
          rawText: seed.rawText
        )
      )
    }
  }

  private func clearResults() {
    similarScore = nil
    differentScore = nil
    vectorDimension = nil
    elapsedSeconds = nil
  }

  private func formattedScore(_ score: Float?) -> String {
    guard let score else {
      return "Not run"
    }
    return score.formatted(
      .number.precision(.fractionLength(4))
    )
  }
}

private struct MemorySeed {
  let sourceMessageID: String
  let rawText: String
}

private struct MemoryRunOutput {
  let storedCount: Int
  let results: [RetrievedMemoryObservation]
}
