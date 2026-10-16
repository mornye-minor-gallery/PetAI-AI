import Foundation
import XCTest
@testable import EdgeLLM

private final class RecallTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    private var exits: [[String: String]] = []
    func log(_ message: String) { lock.withLock { messages.append(message) } }
    func mark(_ name: String, _ fields: [String: String]) {
        if name == "memory.recall.exit" { lock.withLock { exits.append(fields) } }
    }
    var logs: [String] { lock.withLock { messages } }
    var results: [[String: String]] { lock.withLock { exits } }
    var diagnostics: ChatDiagnostics {
        .init(mark: mark, prepared: { _, _, _, _ in }, generated: { _, _ in })
    }
}

private struct PrivateRecallError: LocalizedError {
    var errorDescription: String? { "synthetic-private-query-and-memory" }
}

private struct RecallTestClassifier: MemoryObservationClassifying {
    let version = "recall-failure-test"
    func evaluate(_ text: String) throws -> MemoryGateDecision { throw PrivateRecallError() }
}

private struct RecallTestEmbedder: TextEmbeddingProviding {
    let modelID = "recall-failure-test"
    let dimension = 3
    var error: (any Error)?
    func embedQuery(_ text: String) throws -> [Float] {
        if let error { throw error }
        return [1, 0, 0]
    }
    func embedDocument(_ text: String) -> [Float] { [1, 0, 0] }
}

final class ChatMemoryRecallFailureTests: XCTestCase {
    func testRedactingHostReceivesSafeFailureOnPublicChannelOnly() async throws {
        let privateTelemetry = RecallTelemetry(), publicTelemetry = RecallTelemetry()
        let fixture = try ChatControllerFixture(publicLog: publicTelemetry.log, log: privateTelemetry.log)
        defer { fixture.remove() }
        await fixture.memory.failRecall(with: PrivateRecallError())
        _ = await fixture.controller.recallMemories(userMessage: "synthetic-private-query", excludingTurnIDs: [])
        XCTAssertEqual(publicTelemetry.logs, ["Memory recall failed; chat continues without recalled context: code=retrieval_failed"])
        XCTAssertTrue(privateTelemetry.logs.isEmpty)
        await fixture.controller.logger.error("synthetic-private-message")
        XCTAssertEqual(privateTelemetry.logs, ["synthetic-private-message"])
        XCTAssertEqual(publicTelemetry.logs.count, 1)
    }

    func testDenseSearchFailuresReachChatAsDistinctSafeCodes() async throws {
        // Real SQLite loader, production retriever and MemoryEngine, then the chat fallback boundary.
        for stage in ["success", "embedding_failed", "store_read_failed", "cancelled"] {
            let telemetry = RecallTelemetry()
            let fixture = try ChatControllerFixture(diagnostics: telemetry.diagnostics, log: telemetry.log)
            defer { fixture.remove() }
            let store = SQLiteObservationStore(databaseURL: fixture.directory.appendingPathComponent("memory.sqlite3"))
            let error: (any Error)? = stage == "embedding_failed" ? PrivateRecallError()
                : stage == "cancelled" ? CancellationError() : nil
            let retriever = DenseMemoryRetriever(candidateLoader: store, embedder: RecallTestEmbedder(error: error))
            let engine = MemoryEngine(store: store, classifier: RecallTestClassifier(), retriever: retriever,
                                      securityRequirement: .allowsUnencryptedAppPrivatePrototype)
            try await engine.prepare()
            if stage == "store_read_failed" { await store.close() }
            await fixture.memory.useRecallEngine(engine)
            let memories = await fixture.controller.recallMemories(userMessage: "synthetic-private-query", excludingTurnIDs: [])
            XCTAssertTrue(memories.isEmpty)
            if stage == "success" {
                XCTAssertEqual(telemetry.results, [["status": "success", "recalled_memory_count": "0"]])
                XCTAssertTrue(telemetry.logs.isEmpty)
            } else {
                XCTAssertEqual(telemetry.results, [["status": stage == "cancelled" ? "cancelled" : "error",
                    "failure_code": stage, "recalled_memory_count": "0"]])
                XCTAssertEqual(telemetry.logs, ["Memory recall failed; chat continues without recalled context: code=\(stage)"])
            }
            await engine.close()
        }
    }

    func testInvalidRequestAndMissingRetrieverAreFailures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recall-validation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteObservationStore(databaseURL: directory.appendingPathComponent("memory.sqlite3"))
        let engine = MemoryEngine(store: store, classifier: RecallTestClassifier())
        let scope = MemoryScope(userID: "synthetic-user", characterID: "test")
        do {
            _ = try await engine.recall(.init(scope: scope, query: "질문", topK: 0))
            XCTFail("Invalid limit must throw")
        } catch {
            XCTAssertEqual(error as? MemoryEngineError, .invalidSearchLimit)
            XCTAssertEqual(MemorySearchFailure.diagnosticCode(for: error), "invalid_request")
        }
        do {
            _ = try await engine.recall(.init(scope: scope, query: "질문"))
            XCTFail("Missing retriever must throw")
        } catch {
            XCTAssertEqual(error as? MemorySearchFailure, .retrieverUnavailable)
        }
    }

    func testFailureIsObservableWithoutDiagnosticInstrumentationOrPrivateText() async throws {
        let telemetry = RecallTelemetry()
        let fixture = try ChatControllerFixture(log: telemetry.log)
        defer { fixture.remove() }
        await fixture.memory.failRecall(with: PrivateRecallError())
        let result = await fixture.controller.recallMemories(userMessage: "synthetic-private-query", excludingTurnIDs: [])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(telemetry.logs, ["Memory recall failed; chat continues without recalled context: code=retrieval_failed"])
    }

    func testFailureIsNotCountedAsSuccessfulEmptySearchAndChatContinues() async throws {
        let telemetry = RecallTelemetry()
        let fixture = try ChatControllerFixture(diagnostics: telemetry.diagnostics, log: telemetry.log)
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.memory.failRecall(with: PrivateRecallError())
        await fixture.controller.send(json: fixture.request("recall-failure", "안녕"))
        XCTAssertTrue(fixture.events.snapshot().contains { $0.requestId == "recall-failure" && $0.type == "completed" })
        XCTAssertEqual(telemetry.results, [["status": "error", "failure_code": "retrieval_failed", "recalled_memory_count": "0"]])
        XCTAssertFalse(telemetry.logs.joined().contains("synthetic-private-query-and-memory"))
    }

    func testEmptySearchRemainsSuccessful() async throws {
        let telemetry = RecallTelemetry()
        let fixture = try ChatControllerFixture(diagnostics: telemetry.diagnostics, log: telemetry.log)
        defer { fixture.remove() }
        let result = await fixture.controller.recallMemories(userMessage: "관련 기억이 없는 질문", excludingTurnIDs: [])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(telemetry.results, [["status": "success", "recalled_memory_count": "0"]])
        XCTAssertTrue(telemetry.logs.isEmpty)
    }
}
