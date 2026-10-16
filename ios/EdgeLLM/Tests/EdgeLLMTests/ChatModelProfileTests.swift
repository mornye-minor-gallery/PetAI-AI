import Foundation
import XCTest
@testable import EdgeLLM

final class ChatModelProfileTests: XCTestCase {
    func testLaunchSnapshotRejectsLateModelSwitch() {
        let selection = ChatModelLaunchSelection()
        XCTAssertTrue(selection.configure(.e4b))
        XCTAssertEqual(selection.capture(), .e4b)
        XCTAssertFalse(selection.configure(.e2b))
        XCTAssertTrue(selection.configure(.e4b))
        XCTAssertEqual(selection.capture(), .e4b)
    }

    func testProfilesHaveIndependentCacheAndAdmissionPolicies() throws {
        XCTAssertEqual(ChatModelProfile.e2b.contextTokens, 4096)
        XCTAssertEqual(ChatModelProfile.e4b.contextTokens, 4096)
        XCTAssertEqual(ChatModelProfile.e2b.iosCPUAdmission.requiredBytes, 1_073_741_824)
        XCTAssertEqual(ChatModelProfile.e4b.iosCPUAdmission.requiredBytes, 1_342_177_280)
        XCTAssertNotEqual(ChatModelProfile.e2b.cacheNamespace, ChatModelProfile.e4b.cacheNamespace)
        XCTAssertNil(ChatModelProfile(rawValue: "unknown"))
    }

    func testOptionalModelUsesSharedEmbeddingAndNeverFallsBackToE2B() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = RuntimeModelAssets(languageModelURL: root.appendingPathComponent("base.litertlm"),
            embeddingModelURL: root.appendingPathComponent("embedding.tflite"),
            tokenizerURL: root.appendingPathComponent("tokenizer.model"), version: "base")
        XCTAssertEqual(try ChatModelProfile.e2b.resolve(base: base, documents: root), base)
        XCTAssertThrowsError(try ChatModelProfile.e4b.resolve(base: base, documents: root))
        let file = root.appendingPathComponent(ChatModelProfile.e4b.optionalRelativePath!)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        XCTAssertThrowsError(try ChatModelProfile.e4b.resolve(base: base, documents: root))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(ChatModelProfile.e4b.byteLength!))
        try handle.close()
        let selected = try ChatModelProfile.e4b.resolve(base: base, documents: root)
        XCTAssertEqual(selected.languageModelURL, file)
        XCTAssertEqual(selected.embeddingModelURL, base.embeddingModelURL)
        XCTAssertEqual(selected.tokenizerURL, base.tokenizerURL)
        XCTAssertThrowsError(try ChatModelProfile.e4b.validateDigest("wrong"))
        XCTAssertNoThrow(try ChatModelProfile.e4b.validateDigest(ChatModelProfile.e4b.sha256!))
        XCTAssertThrowsError(try ChatModelProfile.e2b.validateDigest(ChatModelProfile.e4b.sha256!))
    }
}
