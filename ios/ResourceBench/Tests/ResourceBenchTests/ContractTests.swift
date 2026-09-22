import Foundation
import XCTest
@testable import ResourceBench
final class ContractTests: XCTestCase {
    func testCachedFullPromptModeUsesSameContract() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../contracts/resource-benchmark/examples/manifest.json").standardizedFileURL
        var plan = try BenchJSON.decoder.decode(BenchPlan.self, from: Data(contentsOf: file))
        plan.generation.conversation_mode = "cached_full_prompt"
        try plan.validate()
        plan.generation.conversation_mode = "unknown"
        XCTAssertThrowsError(try plan.validate())
    }

    func testPythonManifestExampleDecodesAndValidates() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../contracts/resource-benchmark/examples/manifest.json").standardizedFileURL
        let plan = try BenchJSON.decoder.decode(BenchPlan.self, from: Data(contentsOf: file))
        try plan.validate()
        XCTAssertEqual(plan.generation.context_tokens, 8096)
        XCTAssertEqual(plan.config.target, "inference")
        XCTAssertEqual(plan.inputs.first?.id, "turn-1")
    }
}
