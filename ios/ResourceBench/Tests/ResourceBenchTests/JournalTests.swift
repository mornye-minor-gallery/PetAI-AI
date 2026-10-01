import Foundation
import XCTest
@testable import ResourceBench
final class JournalTests: XCTestCase {
    func testSealedArtifactsHaveMatchingHashesAndSamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = try RunJournal(root: root, runID: UUID(), processID: UUID())
        try journal.sample(bytes: 123, boundary: "turn_start", turnID: "one")
        try journal.event("turn_start", payload: ["turn_id": "one"])
        try journal.seal(complete: false)
        try journal.sample(bytes: 456, boundary: "turn_end", turnID: "one")
        try journal.seal(complete: true)
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("artifacts.json"))) as! [String: Any]
        XCTAssertEqual(index["complete"] as? Bool, true)
        let files = index["files"] as! [[String: Any]]
        XCTAssertEqual(files.count, 3)
        for file in files {
            let data = try Data(contentsOf: root.appendingPathComponent(file["path"] as! String))
            XCTAssertEqual(BenchIO.digest(data), file["sha256"] as? String)
        }
    }
    func testMemoryQueryReturnsFootprintOrExplicitFailure() throws {
        let value = try ResourceSampler.footprint()
        XCTAssertGreaterThan(value, 0)
    }
    func testFileHashDoesNotRetainFileSizedAutoreleasedBuffers() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 128 * 1024 * 1024); try handle.close()
        defer { try? FileManager.default.removeItem(at: file) }
        try autoreleasepool {
            let before = try ResourceSampler.footprint()
            _ = try BenchIO.digestFile(file)
            let after = try ResourceSampler.footprint()
            XCTAssertLessThan(Int64(after) - Int64(before), 32 * 1024 * 1024)
        }
    }

}
