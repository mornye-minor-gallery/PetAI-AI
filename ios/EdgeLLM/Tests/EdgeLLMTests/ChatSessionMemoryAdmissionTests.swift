import XCTest
@testable import EdgeLLM

final class ChatSessionMemoryAdmissionTests: XCTestCase {
    func testSwitchingCharacterWhileDeferredDoesNotRequestDownloadOrInitializeConversation() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.runtime.setModelLoadFailure(.init(availableBytes: 0, requiredBytes: 1_073_741_824))
        await fixture.controller.initialize()
        await fixture.controller.activateCharacter("lucia")
        XCTAssertEqual(fixture.events.snapshot().last?.code, "model_memory_insufficient")
        let selected = await fixture.controller.selectedCharacterID
        XCTAssertEqual(selected, "lucia")
        XCTAssertFalse(fixture.events.snapshot().contains { $0.type == "model_required" || $0.type == "ready" })
        await fixture.runtime.setModelLoadFailure(nil)
        await fixture.controller.initialize()
        XCTAssertEqual(fixture.events.snapshot().last?.type, "ready")
    }

    func testAdmissionBoundaryIncludingZeroHeadroom() throws {
        let policy = ModelLoadMemoryAdmission(requiredBytes: 1_073_741_824)
        for available: UInt64 in [0, 1_073_741_823] {
            XCTAssertThrowsError(try policy.check(availableBytes: available)) {
                XCTAssertEqual($0 as? ModelLoadMemoryDeferred,
                    .init(availableBytes: available, requiredBytes: policy.requiredBytes))
            }
        }
        XCTAssertNoThrow(try policy.check(availableBytes: policy.requiredBytes))
        XCTAssertNoThrow(try policy.check(availableBytes: UInt64.max))
    }

    func testStoredDiaryAndHistoryRemainReadableAndRepeatedDeferralKeepsReason() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.controller.send(json: fixture.request("saved", "반가워"))
        let saved = try Data(contentsOf: fixture.store.fileURL)
        _ = try await fixture.memory.insertDiaryIfAbsent(characterID: "test", localDate: "2026-10-15",
            draft: .init(title: "하루", body: "쉬었어요."))
        // A new process restores the same persisted history even if model loading defers.
        let recorder = ChatEventRecorder()
        let controller = ChatSessionController(runtime: fixture.runtime, memory: fixture.memory,
            platform: ChatTestPlatform(store: fixture.store, personaEnabled: false), eventSink: recorder.receive)
        await fixture.runtime.setModelLoadFailure(.init(availableBytes: 0, requiredBytes: 1_073_741_824))
        await controller.initialize()
        await controller.emitState()
        XCTAssertEqual(recorder.snapshot().last?.code, "model_memory_insufficient")
        XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), saved)
        XCTAssertTrue(recorder.snapshot().contains { $0.type == "history_restored" && !($0.recentEntries ?? []).isEmpty })
        await controller.listDiaries(requestId: "read")
        XCTAssertEqual(recorder.snapshot().last?.diaries?.count, 1)
        await controller.requestDiary(requestId: "new", localDate: "2026-10-16")
        for _ in 0..<100 {
            if recorder.snapshot().contains(where: { $0.requestId == "new" && $0.type == "diary_failed" }) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(recorder.snapshot().contains { $0.requestId == "new" && $0.code == "diary_unavailable" })
        let diaryGenerations = await fixture.runtime.diaryGenerationCount
        XCTAssertEqual(diaryGenerations, 0)
        await controller.recordHomeLine(json: "{\"id\":\"home-deferred\",\"text\":\"오늘도 반가워.\"}")
        XCTAssertEqual(recorder.snapshot().last?.type, "home_line_recorded")
        await controller.emitState()
        XCTAssertEqual(recorder.snapshot().last?.code, "model_memory_insufficient")
    }

    func testDeferredLoadDoesNotRequestDownloadOrStartEmbeddingAndCanRetry() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.runtime.setModelLoadFailure(.init(availableBytes: 0, requiredBytes: 1_073_741_824))
        await fixture.controller.initialize()
        let events = fixture.events.snapshot()
        XCTAssertTrue(events.contains { $0.type == "error" && $0.code == "model_memory_insufficient" })
        XCTAssertFalse(events.contains { $0.type == "model_required" || $0.type == "ready" })
        XCTAssertTrue(events.contains { $0.type == "history_restored" })
        let embeddingLoads = await fixture.memory.preparationCount
        XCTAssertEqual(embeddingLoads, 0)
        await fixture.controller.send(json: fixture.request("blocked", "안녕"))
        let generations = await fixture.runtime.generationCount
        XCTAssertEqual(generations, 0)
        await fixture.runtime.setModelLoadFailure(nil)
        await fixture.controller.initialize()
        XCTAssertEqual(fixture.events.snapshot().last?.type, "ready")
        let attempts = await fixture.runtime.modelPreparationCount
        XCTAssertEqual(attempts, 2)
    }
}
