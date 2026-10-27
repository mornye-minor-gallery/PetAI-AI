import Foundation
import XCTest
@testable import EdgeLLM

final class WorldInfoEmbeddingIdentityTests: XCTestCase {
    func testMultiChunkIdentityMatchesIndependentDigestAndChangesWithContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model.bin")
        let tokenizer = root.appendingPathComponent("tokenizer.bin")
        try Data(repeating: 0xa5, count: 2 * 1024 * 1024 + 17).write(to: model)
        try Data("canary tokenizer".utf8).write(to: tokenizer)
        let identity = try WorldInfoEmbeddingIdentity.make(modelURL: model, tokenizerURL: tokenizer,
                                                           preprocessing: "world-info-v1")
        // Generated independently with Python hashlib over the documented identity contract.
        XCTAssertEqual(identity, "61ca4b41d0542fb60aee7edabd646bcbda488f55e9d4fc758b80702968084f25")
        try Data("changed tokenizer".utf8).write(to: tokenizer)
        XCTAssertNotEqual(try WorldInfoEmbeddingIdentity.make(modelURL: model, tokenizerURL: tokenizer,
                          preprocessing: "world-info-v1"), identity)
    }

    func testMissingFileStillThrows() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try WorldInfoEmbeddingIdentity.make(modelURL: missing, tokenizerURL: missing,
                                                               preprocessing: "world-info-v1"))
    }
}
