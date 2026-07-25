public protocol TextEmbeddingProviding: Sendable {
  var modelID: String { get }
  var dimension: Int { get }

  func embedQuery(_ text: String) async throws -> [Float]
  func embedDocument(_ text: String) async throws -> [Float]
}
