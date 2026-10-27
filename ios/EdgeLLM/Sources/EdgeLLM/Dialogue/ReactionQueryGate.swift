import Foundation
#if os(Android)
import Crypto
#else
import CryptoKit
#endif

/// Selects the reaction search query from the current message. The four votes
/// and thresholds are the frozen `ensemble-bb81762edc8a` policy; the reference
/// examples and their embeddings are exported from the experiment's train split.
public struct ReactionQueryGate: Sendable {
    public enum MessageCount: Int, Sendable { case one = 1, three = 3 }
    public enum GateError: Error { case invalidArtifact, embeddingMismatch, invalidQuery }

    private struct Example: Decodable {
        let current: String
        let nontopical: Bool
    }

    private struct Metadata: Decodable {
        struct Source: Decodable { let indexSHA256: String }
        let version: Int
        let policyID: String
        let embeddingIdentity: String
        let dimension: Int
        let vectorsSHA256: String
        let source: Source
        let examples: [Example]
    }

    private let metadata: Metadata
    private let vectors: [Float]
    private let lexical: ReactionQueryLexicalIndex
    public var embeddingIdentity: String { metadata.embeddingIdentity }

    public init(metadata data: Data, vectors: [Float]) throws {
        let decoded = try JSONDecoder().decode(Metadata.self, from: data)
        guard decoded.version == 1,
              decoded.policyID == "ensemble-bb81762edc8a",
              decoded.dimension > 0,
              decoded.examples.filter(\.nontopical).count >= 5,
              decoded.examples.filter({ !$0.nontopical }).count >= 5,
              vectors.count == decoded.examples.count * decoded.dimension,
              vectors.allSatisfy(\.isFinite),
              decoded.examples.allSatisfy({ !$0.current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw GateError.invalidArtifact }
        for row in decoded.examples.indices {
            let start = row * decoded.dimension
            let norm = vectors[start..<(start + decoded.dimension)].reduce(Float(0)) { $0 + $1 * $1 }
            guard abs(norm - 1) < 0.02 else { throw GateError.invalidArtifact }
        }
        metadata = decoded
        self.vectors = vectors
        lexical = ReactionQueryLexicalIndex(examples: decoded.examples.map(\.current))
    }

    public static func load(directory: URL, suffix: String = "") throws -> Self {
        let metadata = try Data(contentsOf: directory.appendingPathComponent("reaction-query-gate\(suffix).json"))
        let header = try JSONDecoder().decode(Metadata.self, from: metadata)
        let index = try Data(contentsOf: directory.appendingPathComponent("reaction-frames\(suffix).json"))
        let indexDigest = SHA256.hash(data: index).map { String(format: "%02x", $0) }.joined()
        guard indexDigest == header.source.indexSHA256 else { throw GateError.invalidArtifact }
        let data = try Data(contentsOf: directory.appendingPathComponent("reaction-query-prototypes\(suffix).f32"), options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == header.vectorsSHA256, data.count % 4 == 0 else { throw GateError.invalidArtifact }
        let values: [Float] = data.withUnsafeBytes { bytes in
            stride(from: 0, to: data.count, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
        return try Self(metadata: metadata, vectors: values)
    }

    public func select(current: String, embedding: [Float], embeddingIdentity: String) throws -> MessageCount {
        guard embeddingIdentity == metadata.embeddingIdentity else { throw GateError.embeddingMismatch }
        guard embedding.count == metadata.dimension, embedding.allSatisfy(\.isFinite) else { throw GateError.invalidQuery }
        let norm = embedding.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm.isFinite, norm > 0 else { throw GateError.invalidQuery }
        let query = embedding.map { $0 / norm }
        var semantic = [Double]()
        semantic.reserveCapacity(metadata.examples.count)
        for row in metadata.examples.indices {
            var dot: Float = 0
            let start = row * metadata.dimension
            for column in query.indices { dot += vectors[start + column] * query[column] }
            semantic.append(Double(dot))
        }
        let lexicalScores = lexical.scores(current)
        let fused = zip(semantic, lexicalScores).map { 0.6 * $0 + 0.4 * $1 }
        let semanticMargin = margin(semantic, top: 5)
        let lexicalMargin = margin(lexicalScores, top: 5)
        let fusionMargin = margin(fused, top: 3)
        let text = ReactionQueryTextSignals(current)

        // A weight of two on the length vote makes an isolated, complete
        // question the default; one of the three other votes can overturn it.
        let lengthVote = -text.lengthLog >= -0.5112200738910161
        let fusionVote = fusionMargin >= 0.026395212353861747
        let lexicalVote = lexicalMargin >= 0.03681014271122737
        let guidedScore = 16 * semanticMargin
            + 0.5 * text.acknowledgementOnly + 0.5 * text.ellipsisOnly
            + text.reference + 0.5 * text.recall - 2 * text.standaloneRequest
        let guidedVote = guidedScore >= 0.7223179340362549
        let votes = (lengthVote ? 2 : 0) + (fusionVote ? 1 : 0)
            + (lexicalVote ? 1 : 0) + (guidedVote ? 1 : 0)
        return votes >= 3 ? .three : .one
    }

    private func margin(_ scores: [Double], top count: Int) -> Double {
        let topical = zip(scores, metadata.examples).compactMap { $1.nontopical ? nil : $0 }.sorted(by: >)
        let nontopical = zip(scores, metadata.examples).compactMap { $1.nontopical ? $0 : nil }.sorted(by: >)
        let topicalMean = topical.prefix(count).reduce(0, +) / Double(count)
        let nontopicalMean = nontopical.prefix(count).reduce(0, +) / Double(count)
        return nontopicalMean - topicalMean
    }
}
