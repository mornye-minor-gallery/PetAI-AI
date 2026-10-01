import Foundation
import XCTest
@testable import ResourceBench

@MainActor private final class Workload: BenchWorkload {
    var loads = 0
    var turns = 0
    var hold = false
    var continuation: CheckedContinuation<String, Never>?
    func prepare(plan: BenchPlan, modelURL: URL) async throws { loads += 1 }
    func perform(_ input: BenchInput, generation: BenchGeneration) async throws -> String {
        turns += 1
        if hold { return await withCheckedContinuation { continuation = $0 } }
        return "ok"
    }
    func cancel() async {}
}
final class CoordinatorTests: XCTestCase {
    func testFixedScenarioIsAccepted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Data("synthetic model fixture".utf8)
        try model.write(to: root.appendingPathComponent("model"))
        let config = BenchConfig(schema_version: 1, target: "inference", profile: "basic", scenario: "fixed",
            power_window_ms: 20, reply_gap_ms: 0, brightness: 0.5, required_initial_thermal_state: "nominal",
            ram_sample_period_ms: 10, recorder_pre_roll_ms: 1, recorder_post_roll_ms: 1,
            turn_timeout_ms: 1000, prepare_timeout_ms: 1000)
        let plan = BenchPlan(schema_version: 1, run_id: UUID(), owner_id: UUID(), role: "work", config: config,
            model: .init(path: "model", sha256: BenchIO.digest(model)),
            generation: .init(context_tokens: 128, max_output_tokens: 16, temperature: 0.7, top_k: 40,
                              top_p: 1, thinking_enabled: false, conversation_mode: "fresh_per_input"),
            inputs: [.init(id: "one", system_prompt: "test", user_prompt: "hello")])
        XCTAssertNoThrow(try plan.validate())
    }
    @MainActor private func make(scenario: String = "paced", inputCount: Int = 1,
                                 environment: @escaping () throws -> Void = {}) throws -> (RunCoordinator, Workload) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Data("synthetic model fixture".utf8)
        try model.write(to: root.appendingPathComponent("model"))
        let config = BenchConfig(schema_version: 1, target: "inference", profile: "basic", scenario: scenario,
            power_window_ms: 20, reply_gap_ms: 100, brightness: 0.5, required_initial_thermal_state: "nominal",
            ram_sample_period_ms: 10, recorder_pre_roll_ms: 1, recorder_post_roll_ms: 1,
            turn_timeout_ms: 1000, prepare_timeout_ms: 1000)
        let plan = BenchPlan(schema_version: 1, run_id: UUID(), owner_id: UUID(), role: "work", config: config,
            model: .init(path: "model", sha256: BenchIO.digest(model)),
            generation: .init(context_tokens: 128, max_output_tokens: 16, temperature: 0.7, top_k: 40,
                              top_p: 1, thinking_enabled: false, conversation_mode: "fresh_per_input"),
            inputs: (0..<inputCount).map {
                .init(id: "turn-\($0)", system_prompt: "test", user_prompt: "hello")
            })
        let work = Workload()
        let c = try RunCoordinator(root: root.appendingPathComponent("run"), modelsRoot: root, plan: plan,
            manifestHash: String(repeating: "a", count: 64), workload: work, environment: environment, restore: {})
        return (c, work)
    }
    @MainActor func command(_ c: RunCoordinator, operation: String) -> BenchCommand {
        .init(runID: c.plan.run_id, operationID: UUID(), ownerID: c.plan.owner_id,
              expectedRevision: c.store.state.revision, operation: operation,
              manifestSHA256: String(repeating: "a", count: 64))
    }
    @MainActor func testTwoCommandsCannotAcquireSamePhaseBeforeTaskStarts() async throws {
        let (c, _) = try make()
        try c.start()
        let first = command(c, operation: "prepare"), second = command(c, operation: "prepare")
        try c.submit(first, digest: "one")
        XCTAssertThrowsError(try c.submit(second, digest: "two"))
        await c.abort(nil)
    }
    @MainActor func testPrepareAndOneTurnReachDurableFinished() async throws {
        let (c, work) = try make()
        try c.start()
        try c.submit(command(c, operation: "prepare"), digest: "prepare")
        for _ in 0..<100 where c.store.state.phase != .ready { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.store.state.phase, .ready)
        try c.submit(command(c, operation: "begin"), digest: "begin")
        for _ in 0..<100 where !c.store.state.phase.terminal { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.store.state.phase, .finished)
        XCTAssertEqual(work.loads, 1); XCTAssertEqual(work.turns, 1)
        XCTAssertEqual(c.store.state.completedTurns, 1)
    }
    @MainActor func testFixedScenarioRunsEveryInputExactlyOnce() async throws {
        let (c, work) = try make(scenario: "fixed", inputCount: 3)
        try c.start()
        try c.submit(command(c, operation: "prepare"), digest: "prepare")
        for _ in 0..<100 where c.store.state.phase != .ready { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.store.state.phase, .ready)
        try c.submit(command(c, operation: "begin"), digest: "begin")
        for _ in 0..<100 where !c.store.state.phase.terminal { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.store.state.phase, .finished)
        XCTAssertEqual(work.turns, 3)
        XCTAssertEqual(c.store.state.completedTurns, 3)
    }
    @MainActor func testCancelReceiptWaitsForActualWorkCompletion() async throws {
        let (c, work) = try make()
        work.hold = true
        try c.start(); try c.submit(command(c, operation: "prepare"), digest: "prepare")
        for _ in 0..<100 where c.store.state.phase != .ready { try await Task.sleep(for: .milliseconds(5)) }
        try c.submit(command(c, operation: "begin"), digest: "begin")
        for _ in 0..<100 where work.continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(work.continuation)
        let cancel = command(c, operation: "cancel")
        try c.submit(cancel, digest: "cancel")
        try await Task.sleep(for: .milliseconds(5))
        let path = c.store.root.appendingPathComponent("receipts/\(cancel.operationID.uuidString.lowercased()).json")
        var receipt = try BenchJSON.decoder.decode(BenchReceipt.self, from: Data(contentsOf: path))
        XCTAssertEqual(receipt.status, "accepted")
        XCTAssertFalse(c.store.state.phase.terminal)
        work.continuation?.resume(returning: "ok")
        for _ in 0..<100 where !c.store.state.phase.terminal { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(c.store.state.phase, .cancelled)
        try await Task.sleep(for: .milliseconds(5))
        receipt = try BenchJSON.decoder.decode(BenchReceipt.self, from: Data(contentsOf: path))
        XCTAssertEqual(receipt.status, "completed")
    }

    @MainActor func testRejectedCommandDoesNotAbortAnOwnedRun() async throws {
        let (c, _) = try make()
        var stale = command(c, operation: "prepare"); stale.expectedRevision = 99
        let data = try BenchJSON.encoder.encode(stale)
        let name = "\(stale.operationID.uuidString.lowercased()).\(BenchIO.digest(data)).json"
        let commands = c.store.root.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try data.write(to: commands.appendingPathComponent(name))
        try c.start()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(c.store.state.phase, .bootReady)
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.store.root.appendingPathComponent("rejections/" + name).path))
        await c.abort(nil)
    }

    @MainActor func testEnvironmentFailureKeepsTerminalHeartbeatAlive() async throws {
        var fail = false
        let (c, _) = try make(environment: { if fail { throw BenchFailure.invalid("condition_changed") } })
        try c.start(); fail = true
        try await Task.sleep(for: .milliseconds(5400))
        XCTAssertEqual(c.store.state.phase, .failed)
        XCTAssertGreaterThan(c.store.state.heartbeatSeq, 0)
    }

}
