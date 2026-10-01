import Foundation
#if canImport(LiteRTLM)
import LiteRTLM
#endif

nonisolated struct LiteRTLMGenerationMetrics: Sendable {
    let kvTokensBefore: Int?
    let kvTokensAfter: Int?
    let nativeTTFTSeconds: Double?
    let prefillTokens: Int?
    let prefillTokensPerSecond: Double?
    let decodeTokens: Int?
    let decodeTokensPerSecond: Double?
    let measurementError: String?
    let cache: CachedSessionTrace?
    let firstResponseSeconds: Double?
    let generationElapsedSeconds: Double?

    static func capture(
        conversation: any TextSession,
        kvTokensBefore: Int?,
        includeBenchmark: Bool,
        firstResponseSeconds: Double? = nil,
        generationElapsedSeconds: Double? = nil
    ) -> Self {
        var failures: [String] = []
        let kvTokensAfter: Int?
        do {
            let value = try conversation.getTokenCount()
            if value >= 0 {
                kvTokensAfter = value
            } else {
                kvTokensAfter = nil
                failures.append("negative KV token count after generation")
            }
        } catch {
            kvTokensAfter = nil
            if !(conversation is CachedSession) { failures.append("KV token count after generation: \(error.localizedDescription)") }
        }

        var nativeTTFTSeconds: Double?
        var prefillTokens: Int?
        var prefillTokensPerSecond: Double?
        var decodeTokens: Int?
        var decodeTokensPerSecond: Double?
        if includeBenchmark {
            do {
                let benchmark = try conversation.getBenchmarkInfo()
                nativeTTFTSeconds = conversation is CachedSession ? nil : benchmark.timeToFirstTokenInSecond
                prefillTokens = benchmark.lastPrefillTokenCount
                prefillTokensPerSecond = benchmark.lastPrefillTokensPerSecond
                decodeTokens = benchmark.lastDecodeTokenCount
                decodeTokensPerSecond = benchmark.lastDecodeTokensPerSecond
            } catch {
                failures.append("native benchmark: \(error.localizedDescription)")
            }
        }
        if kvTokensBefore == nil && !(conversation is CachedSession) {
            failures.append("KV token count before generation unavailable")
        }

        return .init(
            kvTokensBefore: kvTokensBefore,
            kvTokensAfter: kvTokensAfter,
            nativeTTFTSeconds: nativeTTFTSeconds,
            prefillTokens: prefillTokens,
            prefillTokensPerSecond: prefillTokensPerSecond,
            decodeTokens: decodeTokens,
            decodeTokensPerSecond: decodeTokensPerSecond,
            measurementError: failures.isEmpty ? nil : failures.joined(separator: "; "),
            cache: (conversation as? CachedSession)?.latestCacheTrace(),
            firstResponseSeconds: firstResponseSeconds, generationElapsedSeconds: generationElapsedSeconds
        )
    }
}
