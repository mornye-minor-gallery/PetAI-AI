import Foundation
import Testing
@testable import EdgeLLM

@Test func fatalCheckpointKeepsCompletedTurnAndBlocksNextInference() async throws {
    let fixture = try ChatControllerFixture()
    defer { fixture.remove() }
    await fixture.controller.initialize()
    await fixture.runtime.failCheckpoint(with: RuntimeError.engineRequiresReload)
    await fixture.controller.send(json: fixture.request("first", "안녕"))
    let saved = try #require(try fixture.store.load())
    #expect(saved.chatTurns.last?.status == .completed)
    #expect(fixture.events.snapshot().contains { $0.type == "completed" && $0.requestId == "first" })
    #expect(fixture.events.snapshot().contains { $0.type == "context_failed" })
    let count = await fixture.runtime.generationCount
    await fixture.controller.send(json: fixture.request("blocked", "다음"))
    #expect(await fixture.runtime.generationCount == count)
    #expect(fixture.events.snapshot().last?.code == "runtime_not_ready")
}

@Test func sameFileNameDoesNotMakeDifferentModelsCacheCompatible() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = root.appendingPathComponent("model.litertlm")
    try Data("first".utf8).write(to: model)
    let first = try KVCheckpointStore.modelIdentity(at: model)
    try Data("other".utf8).write(to: model)
    #expect(first != (try KVCheckpointStore.modelIdentity(at: model)))
}

@Test func fatalRestoreDuringOrdinaryPreparationBlocksNextRequest() async throws {
    let fixture = try ChatControllerFixture()
    defer { fixture.remove() }
    await fixture.controller.initialize()
    await fixture.runtime.failPreparation(with: RuntimeError.engineRequiresReload)
    await fixture.controller.send(json: fixture.request("restore", "안녕"))
    await fixture.controller.send(json: fixture.request("blocked", "다음"))
    #expect(fixture.events.snapshot().last?.code == "runtime_not_ready")
    #expect(await fixture.runtime.generationCount == 0)
    #expect(try fixture.store.load()?.chatTurns.count == 1)
}
