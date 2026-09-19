import Foundation
import XCTest
@testable import ResourceBench
final class ContractTests: XCTestCase {
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
