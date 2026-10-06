import Foundation
import XCTest
@testable import EdgeLLM

final class ChatTurnFinalizationTests: XCTestCase {
    private func waitFor(_ type: String, in fixture: ChatControllerFixture) async throws {
        for _ in 0..<1000 {
            if fixture.events.snapshot().contains(where: { $0.type == type }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Missing event: \(type)")
        throw CancellationError()
    }

    private func decide(_ fixture: ChatControllerFixture, id: String = "race",
                        cancelled: Bool, text: String) async throws {
        let data = try JSONEncoder().encode(NativeTurnDecision(requestId: id, cancelled: cancelled, text: text))
        await fixture.controller.finalizeTurn(json: String(decoding: data, as: UTF8.self))
    }

    func testLateCompletionKeepsOnlyDisplayConfirmedPartialOrNoAnswer() async throws {
        for visible in ["", "반"] {
            let fixture = try ChatControllerFixture(automaticallyFinalize: false)
            defer { fixture.remove() }
            await fixture.controller.initialize()
            await fixture.runtime.setResponse("save(P=1,E=0)\n반가워.")
            let request = Task { await fixture.controller.send(json: fixture.request("race", "안녕")) }
            try await waitFor("completion_pending", in: fixture)
            await fixture.controller.cancel()
            try await decide(fixture, cancelled: true, text: visible)
            // A duplicate or contradictory decision cannot resume the writer twice.
            try await decide(fixture, cancelled: false, text: "반가워.")
            await request.value
            let turn = try XCTUnwrap(fixture.store.load()?.chatTurns.last)
            XCTAssertEqual(turn.status, .cancelled)
            XCTAssertEqual(turn.assistantMessage, visible)
            XCTAssertEqual(try fixture.store.load()?.visibleMessages, visible.isEmpty ? 1 : 2)
            let checkpoints = await fixture.runtime.checkpointCount
            let writes = await fixture.memory.writeCount
            XCTAssertEqual(checkpoints, 0)
            XCTAssertEqual(writes, 0)
            XCTAssertFalse(fixture.events.snapshot().contains { $0.type == "completed" })

            let next = Task { await fixture.controller.send(json: fixture.request("next", "이어서")) }
            for _ in 0..<1000 {
                if fixture.events.snapshot().contains(where: { $0.requestId == "next" && $0.type == "completion_pending" }) { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try await decide(fixture, id: "next", cancelled: false, text: "반가워.")
            await next.value
            XCTAssertEqual(try fixture.store.load()?.chatTurns.last?.status, .completed)
        }
    }

    func testStreamCancellationUsesDisplayPrefixNotAllEmittedTokens() async throws {
        let fixture = try ChatControllerFixture(automaticallyFinalize: false)
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.runtime.setHolding(true)
        let request = Task { await fixture.controller.send(json: fixture.request("race", "안녕")) }
        try await waitFor("token", in: fixture)
        await fixture.controller.cancel()
        try await waitFor("cancellation_pending", in: fixture)
        try await decide(fixture, cancelled: true, text: "반")
        await request.value
        XCTAssertEqual(try fixture.store.load()?.chatTurns.last?.assistantMessage, "반")
        XCTAssertEqual(try fixture.store.load()?.chatTurns.last?.status, .cancelled)
    }

    func testForeignDecisionCannotCommitAndValidDecisionCommitsOnce() async throws {
        let fixture = try ChatControllerFixture(automaticallyFinalize: false)
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.runtime.setResponse("save(P=1,E=0)\n반가워.")
        let request = Task { await fixture.controller.send(json: fixture.request("race", "안녕")) }
        try await waitFor("completion_pending", in: fixture)
        try await decide(fixture, id: "old", cancelled: false, text: "반가워.")
        await fixture.controller.cancel(requestID: "old")
        let wasCancelled = await fixture.controller.cancelRequested
        XCTAssertFalse(wasCancelled)
        XCTAssertNotEqual(try fixture.store.load()?.chatTurns.last?.status, .completed)
        try await decide(fixture, cancelled: false, text: "반가워.")
        await fixture.controller.cancel() // Decision ownership has already transferred to the writer.
        try await decide(fixture, cancelled: false, text: "반가워.")
        await request.value
        let checkpoints = await fixture.runtime.checkpointCount
        let writes = await fixture.memory.writeCount
        XCTAssertEqual(checkpoints, 1)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(fixture.events.snapshot().filter { $0.type == "completed" }.count, 1)
    }

    func testInvalidDecisionFailsWithoutSavingUnconfirmedTextOrHanging() async throws {
        let fixture = try ChatControllerFixture(automaticallyFinalize: false)
        defer { fixture.remove() }
        await fixture.controller.initialize()
        let request = Task { await fixture.controller.send(json: fixture.request("race", "안녕")) }
        try await waitFor("completion_pending", in: fixture)
        try await decide(fixture, cancelled: true, text: "존재하지 않는 답변")
        await request.value
        XCTAssertTrue(fixture.events.snapshot().contains { $0.code == "chat_turn_state_failed" })
        XCTAssertEqual(try fixture.store.load()?.chatTurns.last?.assistantMessage, "")
        let checkpoints = await fixture.runtime.checkpointCount
        XCTAssertEqual(checkpoints, 0)
        await fixture.controller.unload()
    }

    func testDeletionDrainsPendingDisplayDecision() async throws {
        let fixture = try ChatControllerFixture(automaticallyFinalize: false)
        defer { fixture.remove() }
        await fixture.controller.initialize()
        let request = Task { await fixture.controller.send(json: fixture.request("race", "안녕")) }
        try await waitFor("completion_pending", in: fixture)
        await fixture.controller.beginDataDeletion(id: "delete", reset: false, removeModels: false)
        try await waitFor("maintenance_ready", in: fixture)
        await request.value
        XCTAssertEqual(try fixture.store.load()?.chatTurns.last?.status, .cancelled)
        XCTAssertEqual(try fixture.store.load()?.chatTurns.last?.assistantMessage, "")
    }

    func testGenerationWaitsForDisplayDecisionBeforePersistingSuccess() async throws {
        let fixture = try ChatControllerFixture(automaticallyFinalize: false)
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.runtime.setResponse("save(P=1,E=0)\n반가워.")
        let request = Task { await fixture.controller.send(json: fixture.request("pending", "안녕")) }
        for _ in 0..<1000 {
            if fixture.events.snapshot().contains(where: {
                $0.type == "completion_pending" || $0.type == "completed"
            }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let events = fixture.events.snapshot()
        XCTAssertTrue(events.contains { $0.type == "completion_pending" })
        XCTAssertFalse(events.contains { $0.type == "completed" })
        XCTAssertNotEqual(try fixture.store.load()?.chatTurns.last?.status, .completed)
        let checkpoints = await fixture.runtime.checkpointCount
        XCTAssertEqual(checkpoints, 0)
        // Closing the host must drain a pending decision without requiring a callback.
        await fixture.controller.unload()
        await request.value
        XCTAssertEqual(try fixture.store.load()?.chatTurns.last?.status, .cancelled)
        XCTAssertEqual(try fixture.store.load()?.chatTurns.last?.assistantMessage, "")
    }
}
