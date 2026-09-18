import Foundation

public struct WorldInfoVectorSettings: Codable, Equatable, Sendable {
    public var queryMessages: Int
    public var maximumEntries: Int
    public var threshold: Double
    /// Initial values follow the reference extension, not measured product optima.
    public init(queryMessages: Int = 2, maximumEntries: Int = 5, threshold: Double = 0.25) {
        self.queryMessages = queryMessages; self.maximumEntries = maximumEntries; self.threshold = threshold
    }
}
public struct WorldInfoVectorMatch: Codable, Equatable, Sendable {
    public let id: String
    public let score: Double
}
public enum WorldInfoVectorError: Error { case invalidSettings, invalidEmbedding }

/// Separate retrieval over authored lore, never the player's EdgeMem store.
public enum WorldInfoVectorSearch {
    public static func search(entries: [WorldInfoEntry], newestMessages: [String], settings: WorldInfoVectorSettings,
                              embedQuery: (String) async throws -> [Float],
                              embedDocument: (String) async throws -> [Float]) async throws -> [WorldInfoVectorMatch] {
        guard settings.queryMessages > 0, settings.queryMessages <= 1000, settings.maximumEntries > 0,
              settings.threshold.isFinite, (-1...1).contains(settings.threshold) else { throw WorldInfoVectorError.invalidSettings }
        let candidates = entries.filter { $0.enabled && $0.rules.vectorized == true && !$0.content.isEmpty }
        let query = newestMessages.prefix(settings.queryMessages).joined(separator: "\n")
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !candidates.isEmpty else { return [] }
        let vector = try await embedQuery(query)
        var results: [(Int, WorldInfoVectorMatch)] = []
        for (i, entry) in candidates.enumerated() {
            try Task.checkCancellation()
            let document = try await embedDocument(entry.content)
            let score = try cosine(vector, document)
            if score >= settings.threshold { results.append((i, .init(id: entry.id, score: score))) }
        }
        return results.sorted { $0.1.score == $1.1.score ? $0.0 < $1.0 : $0.1.score > $1.1.score }
            .prefix(settings.maximumEntries).map { $0.1 }
    }
    static func cosine(_ a: [Float], _ b: [Float]) throws -> Double {
        guard !a.isEmpty, a.count == b.count, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { throw WorldInfoVectorError.invalidEmbedding }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for (x, y) in zip(a, b) { dot += Double(x) * Double(y); aa += Double(x) * Double(x); bb += Double(y) * Double(y) }
        guard aa > 0, bb > 0 else { throw WorldInfoVectorError.invalidEmbedding }
        return max(-1, min(1, dot / sqrt(aa * bb)))
    }
}
