import Foundation
import XCTest
@testable import ResourceBench

final class UnityDiagnosticTests: XCTestCase {
    func testStageIsDurableWithoutFinishingTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try UnityDiagnosticRecorder(root: root, runID: UUID(), samplePeriodMS: 50)
        try recorder.stage("token_measure.begin", fields: ["session_id": "probe"])
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("artifacts.json"))) as! [String: Any]
        XCTAssertEqual(index["complete"] as? Bool, false)
        let files = index["files"] as! [[String: Any]]
        let events = try files.filter { $0["kind"] as? String == "events" }.map {
            try String(contentsOf: root.appendingPathComponent($0["path"] as! String), encoding: .utf8)
        }.joined()
        XCTAssertTrue(events.contains("token_measure.begin"))
        XCTAssertTrue(events.contains("probe"))
        try recorder.finish(error: nil)
    }

    func testHeartbeatAndSamplesFlushWithoutMainThreadOrCompletedTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = try UnityDiagnosticRecorder(root: root, runID: UUID(), samplePeriodMS: 10)
        try recorder.start(flushPeriodMS: 20)
        Thread.sleep(forTimeInterval: 0.10)
        let status = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as! [String: Any]
        XCTAssertGreaterThan(status["heartbeat_seq"] as! Int, 0)
        XCTAssertEqual(status["phase"] as? String, "recording")
        try recorder.finish(error: "synthetic_failure")
        XCTAssertThrowsError(try recorder.stage("late_event"))
        XCTAssertThrowsError(try UnityDiagnosticRecorder(root: root, runID: UUID(), samplePeriodMS: 50))
    }
}
