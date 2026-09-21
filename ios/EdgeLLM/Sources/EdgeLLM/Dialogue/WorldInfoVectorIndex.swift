import Foundation
import CryptoKit

public enum WorldInfoVectorIndexError: Error, Equatable {
    case embeddingIdentityMismatch, invalidSnapshot, duplicateEntry(String), busy
}

/// An authored-lore index, independent of EdgeMem. A single owner serializes refreshes;
/// overlapping refreshes fail explicitly rather than overwriting a newer generation.
public actor WorldInfoVectorIndex {
    private struct Document: Codable, Sendable {
        let hash: String
        let vector: [Float]
    }
    private struct Snapshot: Codable {
        let version: Int
        let embeddingIdentity: String
        let documents: [String: Document]
    }
    private let url: URL?
    private let embeddingIdentity: String
    private var documents: [String: Document]
    private var refreshing = false
    public var documentCount: Int { documents.count }

    public init(url: URL? = nil, embeddingIdentity: String) throws {
        self.url = url
        self.embeddingIdentity = embeddingIdentity
        guard !embeddingIdentity.isEmpty else { throw WorldInfoVectorIndexError.invalidSnapshot }
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
            guard snapshot.version == 1 else { throw WorldInfoVectorIndexError.invalidSnapshot }
            guard snapshot.embeddingIdentity == embeddingIdentity else { throw WorldInfoVectorIndexError.embeddingIdentityMismatch }
            for document in snapshot.documents.values { _ = try WorldInfoVectorSearch.cosine(document.vector, document.vector) }
            documents = snapshot.documents
        } else { documents = [:] }
    }

    /// Pass the active library as a whole. Removed/ineligible entries leave the index at commit.
    /// No partial in-memory or disk update survives a failed embedding or atomic write.
    public func search(entries: [WorldInfoEntry], newestMessages: [String], settings: WorldInfoVectorSettings,
                       embedQuery: @Sendable (String) async throws -> [Float],
                       embedDocument: @Sendable (String) async throws -> [Float]) async throws -> [WorldInfoVectorMatch] {
        guard !refreshing else { throw WorldInfoVectorIndexError.busy }
        refreshing = true
        defer { refreshing = false }
        guard settings.queryMessages > 0, settings.queryMessages <= 1000, settings.maximumEntries > 0,
              settings.threshold.isFinite, (-1...1).contains(settings.threshold) else { throw WorldInfoVectorError.invalidSettings }
        var seen = Set<String>()
        var next: [String: Document] = [:]
        let candidates = entries.filter { $0.enabled && ($0.rules.vectorized == true || settings.enabledForAll == true) && !$0.content.isEmpty }
        for entry in candidates {
            guard seen.insert(entry.id).inserted else { throw WorldInfoVectorIndexError.duplicateEntry(entry.id) }
            try Task.checkCancellation()
            let hash = SHA256.hash(data: Data(entry.content.utf8)).map { String(format: "%02x", $0) }.joined()
            if let cached = documents[entry.id], cached.hash == hash { next[entry.id] = cached }
            else {
                let vector = try await embedDocument(entry.content)
                _ = try WorldInfoVectorSearch.cosine(vector, vector)
                next[entry.id] = Document(hash: hash, vector: vector)
            }
        }
        let query = newestMessages.prefix(settings.queryMessages).joined(separator: "\n")
        var ranked: [(Int, WorldInfoVectorMatch)] = []
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !candidates.isEmpty {
            let vector = try await embedQuery(query)
            for (offset, entry) in candidates.enumerated() {
                let score = try WorldInfoVectorSearch.cosine(vector, next[entry.id]!.vector)
                if score >= settings.threshold { ranked.append((offset, .init(id: entry.id, score: score))) }
            }
        }
        try Task.checkCancellation()
        if let url {
            let data = try JSONEncoder().encode(Snapshot(version: 1, embeddingIdentity: embeddingIdentity, documents: next))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        documents = next
        return ranked.sorted { $0.1.score == $1.1.score ? $0.0 < $1.0 : $0.1.score > $1.1.score }
            .prefix(settings.maximumEntries).map(\.1)
    }
}
