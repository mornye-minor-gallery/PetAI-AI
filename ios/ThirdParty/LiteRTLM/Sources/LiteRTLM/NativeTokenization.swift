import Foundation
import CLiteRTLM

/// Called on the owning Engine actor. Kept separate so the C memory/UTF-8
/// boundary can be exercised without creating Swift conversation wrappers.
enum NativeTokenization {
  static func count(_ text: String, engine: OpaquePointer?) throws -> Int {
    guard let engine else { throw LiteRTLMError.engine(.notInitialized) }
    // The C API receives a null-terminated UTF-8 string, so an embedded null
    // would silently measure only a prefix of the actual prompt.
    guard !text.utf8.contains(0) else { throw LiteRTLMError.engine(.invalidTokenizationInput) }
    guard let result = litert_lm_engine_tokenize(engine, text) else {
      throw LiteRTLMError.engine(.tokenizationFailed)
    }
    defer { litert_lm_tokenize_result_delete(result) }
    guard let count = Int(exactly: litert_lm_tokenize_result_get_num_tokens(result)), count >= 0 else {
      throw LiteRTLMError.engine(.invalidTokenCount)
    }
    return count
  }
}

/// Native template measurement. This is not the number of characters or bytes.
public struct PromptTokenCount: Sendable, Equatable {
  public let cachedTokens: Int
  public let submittedTokens: Int
  public var totalTokens: Int { cachedTokens + submittedTokens }
}
