import Foundation
import Accelerate
import CryptoKit

/// Immutable, offline-built example index. The model/tokenizer identity is checked
/// before ranking so a different embedding space cannot silently select frames.
public struct ReactionFrameIndex: Sendable {
    public struct Frame: Codable, Sendable {
        public let id: String
        public let goal: String
        public let shape: String
        public let example: DialogueContent.Example
        public var entry: WorldInfoEntry {
            var rules = WorldInfoEntryRules()
            rules.depth = 0; rules.role = .system; rules.preventRecursion = true
            // Top-one is mandatory in this experiment. Only the separate lore budget
            // is bypassed; the composer's total input/output budget still applies.
            return .init(id: "reaction." + id, content: "## 응답 참고\n목표: \(goal)\n형태: \(shape)\n예시 대화 (현재의 사실이 아닌 표현 참고):\nuser: \(example.user)\nassistant: \(example.assistant)",
                         constant: true, ignoreBudget: true, position: .inChat, rules: rules)
        }
    }
    private struct Metadata: Decodable {
        let version: Int
        let characterID: String
        let embeddingIdentity: String
        let vectorsSHA256: String?
        let dimension: Int
        let rows: [Int]
        let frames: [Frame]
    }
    public struct Match: Sendable {
        public let frame: Frame
        public let score: Float
        public let exampleRow: Int
        public let searchMilliseconds: Double
    }
    public enum IndexError: Error { case invalidArtifact, embeddingMismatch, invalidQuery }
    private let metadata: Metadata
    private let vectors: [Float]
    public var characterID: String { metadata.characterID }
    public var embeddingIdentity: String { metadata.embeddingIdentity }

    public init(metadata data: Data, vectors: [Float]) throws {
        let m = try JSONDecoder().decode(Metadata.self, from: data)
        guard m.version == 1, m.dimension > 0, !m.rows.isEmpty, !m.frames.isEmpty,
              m.rows.allSatisfy({ m.frames.indices.contains($0) }),
              Set(m.frames.map(\.id)).count == m.frames.count,
              vectors.count / m.dimension == m.rows.count,
              vectors.count % m.dimension == 0, vectors.allSatisfy(\.isFinite) else { throw IndexError.invalidArtifact }
        for row in m.rows.indices {
            let start = row * m.dimension
            let norm = vectors[start..<(start + m.dimension)].reduce(Float(0)) { $0 + $1 * $1 }
            guard abs(norm - 1) < 0.02 else { throw IndexError.invalidArtifact }
        }
        metadata = m; self.vectors = vectors
    }
    public static func load(directory: URL) throws -> Self {
        let metadata = try Data(contentsOf: directory.appendingPathComponent("reaction-frames.json"))
        let header = try JSONDecoder().decode(Metadata.self, from: metadata)
        let data = try Data(contentsOf: directory.appendingPathComponent("reaction-vectors.f32"), options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard header.vectorsSHA256 == digest else { throw IndexError.invalidArtifact }
        guard data.count % 4 == 0 else { throw IndexError.invalidArtifact }
        let floats: [Float] = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
        return try Self(metadata: metadata, vectors: floats)
    }
    /// K counts messages, including the pending user message, not exchanges.
    public static func query(history: [String], current: String) -> String {
        (Array(history.suffix(2)) + [current]).joined(separator: "\n")
    }
    public func search(query: [Float], embeddingIdentity: String) throws -> Match {
        guard embeddingIdentity == metadata.embeddingIdentity else { throw IndexError.embeddingMismatch }
        guard query.count == metadata.dimension, query.allSatisfy(\.isFinite) else { throw IndexError.invalidQuery }
        let norm = sqrt(query.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { throw IndexError.invalidQuery }
        let q = query.map { $0 / norm }
        let start = ProcessInfo.processInfo.systemUptime
        var best = -Float.infinity, winner = 0
        vectors.withUnsafeBufferPointer { matrix in
            q.withUnsafeBufferPointer { query in
                for row in metadata.rows.indices {
                    var score: Float = 0
                    vDSP_dotpr(matrix.baseAddress! + row * metadata.dimension, 1, query.baseAddress!, 1,
                               &score, vDSP_Length(metadata.dimension))
                    if score > best { best = score; winner = row }
                }
            }
        }
        return Match(frame: metadata.frames[metadata.rows[winner]], score: best, exampleRow: winner,
                     searchMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
}

/// A private build-time package, shared by app and evaluation. Lore retains its
/// own keyword selection and budget; reaction selection contributes exactly one entry.
public struct DialogueRetrievalResources: Sendable {
    public let index: ReactionFrameIndex?
    public let lore: WorldInfoSettings?
    public init(directory: URL, characterID: String, reactions: Bool, worldLore: Bool) throws {
        index = reactions ? try ReactionFrameIndex.load(directory: directory) : nil
        guard index == nil || index?.characterID == characterID else { throw ReactionFrameIndex.IndexError.invalidArtifact }
        lore = worldLore ? try JSONDecoder().decode(WorldInfoSettings.self,
            from: Data(contentsOf: directory.appendingPathComponent("dialogue-lore.json"))) : nil
    }
    public func worldInfo(base: WorldInfoSettings?, match: ReactionFrameIndex.Match?) -> WorldInfoSettings? {
        guard base != nil || lore != nil || match != nil else { return nil }
        let settings = base ?? lore
        return .init(tokenBudget: settings?.tokenBudget ?? 1024,
                     entries: (base?.entries ?? []) + (lore?.entries ?? []) + (match.map { [$0.frame.entry] } ?? []),
                     scanDepth: settings?.scanDepth ?? 3, includeNames: settings?.includeNames ?? true,
                     caseSensitive: settings?.caseSensitive ?? false, matchWholeWords: settings?.matchWholeWords ?? false,
                     rules: settings?.rules ?? .init(), library: base?.library)
    }
}
