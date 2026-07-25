public protocol TextEmbeddingProviding: Sendable {
  var modelID: String { get }
  var dimension: Int { get }

  func embedQuery(_ text: String) async throws -> [Float]
  func embedDocument(_ text: String) async throws -> [Float]
}

public protocol ClassificationEmbeddingProviding: Sendable {
  var modelID: String { get }
  var dimension: Int { get }

  func embedClassification(_ text: String) async throws -> [Float]
}
