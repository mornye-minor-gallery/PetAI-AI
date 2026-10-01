import Foundation
import XCTest
@testable import EdgeLLM

final class ChatSessionControllerTests: XCTestCase {
    func testPublicCheckoutDoesNotRequireLearnedRouterWeights() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        let router = await fixture.controller.nativeToolRouter
        XCTAssertNil(router)
        XCTAssertTrue(fixture.events.snapshot().contains { $0.type == "ready" })
    }

    func testControllerLoadsExplicitlySuppliedRouterArtifacts() async throws {
        let artifacts = try makeOwnedRouterFixture()
        let registry = NativeToolRouterArtifactRegistry(manifestSHA256: artifacts.digest) { artifacts.files[$0] }
        let fixture = try ChatControllerFixture(toolRouterArtifacts: registry)
        defer { fixture.remove() }
        await fixture.controller.initialize()
        let router = await fixture.controller.nativeToolRouter
        XCTAssertNotNil(router)
    }

    func testInvalidRouterArtifactsAreNotInstalled() async throws {
        let registry = NativeToolRouterArtifactRegistry(manifestSHA256: "missing") { _ in nil }
        let fixture = try ChatControllerFixture(toolRouterArtifacts: registry)
        defer { fixture.remove() }
        await fixture.controller.initialize()
        let router = await fixture.controller.nativeToolRouter
        XCTAssertNil(router)
    }

    func testCancelledPartialReplyIsDurableAndNextRequestCompletes() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.runtime.setHolding(true)
        let request = Task { await fixture.controller.send(json: fixture.request("cancel", "안녕")) }
        for _ in 0..<1000 {
            if fixture.events.snapshot().contains(where: { $0.type == "token" }) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(fixture.events.snapshot().contains { $0.type == "token" })
        await fixture.controller.cancel()
        await request.value
        let saved = try XCTUnwrap(fixture.store.load()).chatTurns
        XCTAssertEqual(saved.last?.status, .cancelled)
        XCTAssertEqual(saved.last?.assistantMessage, "반가워.")
        let checkpoints = await fixture.runtime.checkpointCount
        XCTAssertEqual(checkpoints, 0)
        await fixture.runtime.setHolding(false)
        await fixture.controller.send(json: fixture.request("next", "이어서 말해 줘"))
        XCTAssertEqual(try fixture.store.load()?.chatTurns.last?.status, .completed)
    }

    func testFailedAdmissionDoesNotBeginInference() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        try Data("not-a-directory".utf8).write(to: fixture.directory)
        await fixture.controller.send(json: fixture.request("cannot-save", "안녕"))
        let generations = await fixture.runtime.generationCount
        XCTAssertEqual(generations, 0)
        XCTAssertTrue(fixture.events.snapshot().contains { $0.code == "chat_turn_storage_failed" })
    }

    func testUnloadDrainsTheCompletedTurnMemoryWriter() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.memory.holdWrites()
        await fixture.runtime.setResponse("save(P=1,E=0)\n기억할게.")
        let request = Task { await fixture.controller.send(json: fixture.request("write", "나는 매운 음식을 좋아해")) }
        for _ in 0..<1000 {
            if await fixture.memory.writeStarted { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await fixture.memory.writeStarted
        XCTAssertTrue(started)
        let unload = Task { await fixture.controller.unload() }
        try await Task.sleep(nanoseconds: 20_000_000)
        let closedTooEarly = await fixture.memory.closedDuringWrite
        await fixture.memory.finishWrite()
        await request.value
        await unload.value
        XCTAssertFalse(closedTooEarly)
    }

    func testUnsupportedToolsDoNotRunInferenceOrReportSuccess() async throws {
        let artifacts = try makeOwnedRouterFixture()
        let registry = NativeToolRouterArtifactRegistry(manifestSHA256: artifacts.digest) { artifacts.files[$0] }
        let fixture = try ChatControllerFixture(toolRouterArtifacts: registry)
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.controller.send(json: fixture.request("tool-1", "내일 아침 7시에 알람 맞춰 줘"))
        let events = fixture.events.snapshot()
        XCTAssertTrue(events.contains { $0.requestId == "tool-1" && $0.code == "platform_unsupported" })
        XCTAssertFalse(events.contains { $0.requestId == "tool-1" && $0.type == "completed" })
        let calls = await fixture.runtime.generationCount
        XCTAssertEqual(calls, 0)
    }

    func testRequestIdentityAndCompletedTurnAreSharedWithStorage() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.controller.send(json: fixture.request("unity-request", "안녕"))
        let events = fixture.events.snapshot()
        XCTAssertEqual(events.last(where: { $0.type == "completed" })?.requestId, "unity-request")
        let saved = try XCTUnwrap(fixture.store.load())
        XCTAssertEqual(saved.chatTurns.last?.requestID, "unity-request")
        XCTAssertEqual(saved.chatTurns.last?.assistantMessage, "반가워.")
        XCTAssertEqual(saved.chatTurns.last?.status, .completed)
        let checkpoints = await fixture.runtime.checkpointCount
        XCTAssertEqual(checkpoints, 1)
    }

    func testTwentyFirstAdmissionExcludesOnlyTheCurrentWindow() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        for index in 1...21 {
            await fixture.controller.send(json: fixture.request("turn-\(index)", "질문 \(index)"))
        }
        let excluded = await fixture.memory.lastExcluded
        XCTAssertEqual(excluded, Set((2...21).map { "turn-\($0)" }))
        let saved = try XCTUnwrap(fixture.store.load())
        XCTAssertEqual(saved.chatTurns.map(\.requestID), (2...21).map { "turn-\($0)" })
    }
}
