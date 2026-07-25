import EdgeLLM
import EmbeddingGemmaNative
import Foundation

enum EmbeddingGemmaRuntimeError: Error {
  case emptyText
  case modelFileMissing(path: String)
  case tokenizerFileMissing(path: String)
  case unexpectedDimension(expected: Int, actual: Int)
  case malformedOutput(byteCount: Int)
  case nonFiniteOutput(index: Int)
  case notPrepared
}

extension EmbeddingGemmaRuntimeError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .emptyText:
      "Embedding text must not be empty."
    case .modelFileMissing(let path):
      "EmbeddingGemma model was not found at \(path)."
    case .tokenizerFileMissing(let path):
      "SentencePiece tokenizer was not found at \(path)."
    case .unexpectedDimension(let expected, let actual):
      "Expected a \(expected)-value embedding, but received \(actual)."
    case .malformedOutput(let byteCount):
      "LiteRT returned an invalid embedding payload of \(byteCount) bytes."
    case .nonFiniteOutput(let index):
      "Embedding output contains a non-finite value at index \(index)."
    case .notPrepared:
      "Prepare the EmbeddingGemma model and tokenizer first."
    }
  }
}

actor EmbeddingGemmaEmbedder: TextEmbeddingProviding {
  nonisolated let modelID =
    "litert-community/embeddinggemma-300m-seq256-mixed-precision"
  nonisolated let dimension = 768

  private let sequenceLength = 256
  private var runner: PETEmbeddingGemmaRunner?

  func prepare(modelURL: URL, tokenizerURL: URL) throws {
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw EmbeddingGemmaRuntimeError.modelFileMissing(
        path: modelURL.path
      )
    }
    guard FileManager.default.fileExists(atPath: tokenizerURL.path) else {
      throw EmbeddingGemmaRuntimeError.tokenizerFileMissing(
        path: tokenizerURL.path
      )
    }

    let candidate = try PETEmbeddingGemmaRunner(
      modelPath: modelURL.path,
      tokenizerPath: tokenizerURL.path,
      sequenceLength: sequenceLength
    )
    guard candidate.dimension == dimension else {
      throw EmbeddingGemmaRuntimeError.unexpectedDimension(
        expected: dimension,
        actual: candidate.dimension
      )
    }
    runner = candidate
  }

  func embedQuery(_ text: String) throws -> [Float] {
    try embed(
      text,
      prefix: "task: search result | query: "
    )
  }

  func embedDocument(_ text: String) throws -> [Float] {
    try embed(
      text,
      prefix: "title: none | text: "
    )
  }

  func unload() {
    runner = nil
  }

  private func embed(
    _ text: String,
    prefix: String
  ) throws -> [Float] {
    let normalizedText = text.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !normalizedText.isEmpty else {
      throw EmbeddingGemmaRuntimeError.emptyText
    }
    guard let runner else {
      throw EmbeddingGemmaRuntimeError.notPrepared
    }

    let data = try runner.embedding(
      forText: prefix + normalizedText
    )
    let floatSize = MemoryLayout<Float>.stride
    guard data.count.isMultiple(of: floatSize) else {
      throw EmbeddingGemmaRuntimeError.malformedOutput(
        byteCount: data.count
      )
    }

    let count = data.count / floatSize
    guard count == dimension else {
      throw EmbeddingGemmaRuntimeError.unexpectedDimension(
        expected: dimension,
        actual: count
      )
    }

    var vector = [Float](repeating: 0, count: count)
    _ = vector.withUnsafeMutableBytes { destination in
      data.copyBytes(to: destination)
    }

    if let index = vector.firstIndex(where: { !$0.isFinite }) {
      throw EmbeddingGemmaRuntimeError.nonFiniteOutput(index: index)
    }
    return vector
  }
}
