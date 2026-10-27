import Foundation

/// Safe search-stage errors. Underlying native errors can contain queries, stored text or file paths.
public enum MemorySearchFailure: String, Error, Equatable, Sendable {
    case retrieverUnavailable = "retriever_unavailable"
    case embeddingFailed = "embedding_failed"
    case storeReadFailed = "store_read_failed"
    case scoringFailed = "scoring_failed"

    static func diagnosticCode(for error: Error) -> String {
        switch error {
        case let failure as MemorySearchFailure: return failure.rawValue
        case is CancellationError: return "cancelled"
        case MemoryEngineError.invalidSearchLimit: return "invalid_request"
        case MemoryEngineError.notPrepared: return "not_prepared"
        case let failure as DenseMemoryRetrieverError:
            switch failure {
            case .invalidQueryDimension, .nonFiniteQueryEmbedding: return "invalid_query_embedding"
            case .emptyQuery, .invalidSearchLimit, .invalidMinimumSimilarity: return "invalid_request"
            }
        default: return "retrieval_failed"
        }
    }
}
