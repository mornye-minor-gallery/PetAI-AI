import Foundation
import XCTest
@testable import EdgeLLM

final class ChatCharacterSwitchTests: XCTestCase {
    func testSwitchRestoresEachCharactersConversationWithoutReloadingModel() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.controller.send(json: fixture.request("first", "첫 번째 대화"))
        await NativePreparationContext.$requestID.withValue("switch-lucia") {
            await fixture.controller.activateCharacter("lucia")
        }
        let switchEvents = fixture.events.snapshot().filter { ["loading", "history_restored", "ready"].contains($0.type)
            && $0.requestId == "switch-lucia" }
        XCTAssertEqual(switchEvents.map(\.type), ["loading", "history_restored", "ready"])
        await fixture.controller.send(json: fixture.request("second", "두 번째 대화", characterID: "lucia"))
        await fixture.controller.activateCharacter("test")
        await fixture.controller.send(json: fixture.request("third", "돌아온 뒤의 대화"))

        let entries = fixture.events.snapshot().last(where: { $0.type == "history_restored" })?.recentEntries
        XCTAssertEqual(entries?.map(\.id), ["first"])
        XCTAssertEqual(try fixture.store.load()?.chatTurns.map(\.requestID), ["first", "third"])
        let recalledCharacterIDs = await fixture.memory.recalledCharacterIDs
        XCTAssertEqual(recalledCharacterIDs, ["test", "lucia", "test"])
        let modelPreparations = await fixture.runtime.modelPreparationCount
        XCTAssertEqual(modelPreparations, 1)
    }

    func testSwitchDuringGenerationKeepsTheCurrentCharacter() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.runtime.setHolding(true)
        let request = Task { await fixture.controller.send(json: fixture.request("in-flight", "안녕")) }
        for _ in 0..<1000 {
            if fixture.events.snapshot().contains(where: { $0.type == "token" }) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await fixture.controller.activateCharacter("lucia")
        XCTAssertTrue(fixture.events.snapshot().contains { $0.code == "runtime_busy" })
        await fixture.controller.cancel()
        await request.value
        await fixture.runtime.setHolding(false)
        await fixture.controller.send(json: fixture.request("after", "계속"))
        XCTAssertEqual(try fixture.store.load()?.chatTurns.last?.requestID, "after")
    }

    func testFailedSwitchKeepsPreviousCharacterAvailableForRecovery() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.runtime.failPreparation(with: RuntimeError.runtimeBusy)
        await fixture.controller.activateCharacter("lucia")
        XCTAssertTrue(fixture.events.snapshot().contains { $0.code == "character_activation_failed" })
        await fixture.runtime.clearPreparationFailure()
        await fixture.controller.initialize()
        await fixture.controller.send(json: fixture.request("recovered", "다시 대화"))
        XCTAssertEqual(try fixture.store.load()?.chatTurns.last?.requestID, "recovered")
    }
}
