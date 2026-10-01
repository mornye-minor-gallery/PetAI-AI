import Foundation
import XCTest
@testable import EdgeLLM

final class DownloadedModelAssetsTests: XCTestCase {
    func testResolvesManifestRolesInsteadOfFixedModelNames() throws {
        try withPackage { root in
            let assets = try XCTUnwrap(DownloadedModelAssets.installed(in: root))
            XCTAssertEqual(assets.languageModelURL.lastPathComponent, "text-only.litertlm")
            XCTAssertEqual(assets.version, "test-v1")
        }
    }

    func testMissingOrTruncatedFileIsNotReady() throws {
        try withPackage { root in
            try Data().write(to: root.appendingPathComponent("PetAIModels/text-only.litertlm"))
            XCTAssertNil(DownloadedModelAssets.installed(in: root))
        }
    }

    func testPathOutsidePackageIsRejected() throws {
        try withPackage(path: "PetAIModels/../outside.litertlm") { root in
            XCTAssertNil(DownloadedModelAssets.installed(in: root))
        }
    }

    private func withPackage(path: String = "PetAIModels/text-only.litertlm",
                             _ run: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("PetAIModels"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [("LANGUAGE_MODEL", path), ("EMBEDDING_MODEL", "PetAIModels/embed.tflite"),
                     ("TOKENIZER", "PetAIModels/tokenizer.model")]
        for (_, file) in files { try Data([1]).write(to: root.appendingPathComponent(file)) }
        let manifest: [String: Any] = ["version": "test-v1", "files": files.map {
            ["role": $0.0, "relativePath": $0.1, "byteLength": 1] as [String: Any]
        }]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("PetAIModels/manifest.json"))
        try run(root)
    }
}
