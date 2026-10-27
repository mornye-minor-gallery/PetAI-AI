import Foundation
import Testing
@testable import EdgeLLM

final class InferenceAdmissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked: Set<InferenceOperation> = []
    private var calls: [InferenceOperation] = []
    func block(_ operations: Set<InferenceOperation>) { lock.withLock { blocked = operations } }
    func check(_ operation: InferenceOperation) throws {
        try lock.withLock {
            calls.append(operation)
            if blocked.contains(operation) {
                throw InferenceMemoryDeferred(availableBytes: 0, requiredBytes: 100, pressure: .normal)
            }
        }
    }
    func count(_ operation: InferenceOperation) -> Int { lock.withLock { calls.filter { $0 == operation }.count } }
}

@Test func inferencePolicySeparatesPressureFromAppHeadroom() throws {
    let policy = InferenceMemoryAdmission(requiredBytes: 100)
    #expect(throws: InferenceMemoryDeferred.self) { try policy.check(availableBytes: 0, pressure: .normal) }
    #expect(throws: InferenceMemoryDeferred.self) { try policy.check(availableBytes: 99, pressure: .normal) }
    #expect(throws: InferenceMemoryDeferred.self) { try policy.check(availableBytes: 1000, pressure: .warning) }
    #expect(throws: InferenceMemoryDeferred.self) { try policy.check(availableBytes: 1000, pressure: .critical) }
    try policy.check(availableBytes: 100, pressure: .normal)
}

@Test func memoryRejectionDoesNotAcceptOrPersistTheQuestionAndRetryChecksAgain() async throws {
    let probe = InferenceAdmissionProbe()
    let fixture = try ChatControllerFixture(checkInferenceAdmission: probe.check)
    defer { fixture.remove() }
    await fixture.controller.initialize()
    probe.block([.dialogue])
    await fixture.controller.send(json: fixture.request("blocked", "안녕"))
    #expect(fixture.events.snapshot().last?.code == "inference_memory_insufficient")
    #expect(await fixture.runtime.generationCount == 0)
    #expect(try fixture.store.load()?.chatTurns.isEmpty ?? true)
    #expect(!fixture.events.snapshot().contains { $0.requestId == "blocked" && $0.type == "generating" })
    await fixture.controller.recordHomeLine(json: "{\"id\":\"home\",\"text\":\"반가워\"}")
    #expect(fixture.events.snapshot().last?.type == "home_line_recorded")
    probe.block([])
    await fixture.controller.send(json: fixture.request("retry", "안녕"))
    #expect(await fixture.runtime.generationCount == 1)
    #expect(probe.count(.dialogue) == 2)
    #expect(try fixture.store.load()?.chatTurns.map(\.requestID) == ["retry"])
}

@Test func storedDiaryDoesNotNeedMemoryAdmissionButNewDiaryDoes() async throws {
    let probe = InferenceAdmissionProbe()
    let fixture = try ChatControllerFixture(checkInferenceAdmission: probe.check)
    defer { fixture.remove() }
    await fixture.controller.initialize()
    let day = try DailyDiaryDay("2026-10-15")
    let evidence = MemoryObservation(id: "memory", turnID: "turn", sessionID: "session", sequence: 1,
        scope: .init(userID: "local-user", characterID: "test"), occurredAt: day.start,
        rawText: "산책했어요", labelEvidence: [], createdAt: day.start)
    await fixture.memory.setDiaryObservations([evidence])
    probe.block([.diary])
    await fixture.controller.requestDiary(requestId: "new", localDate: day.key)
    for _ in 0..<1000 {
        if fixture.events.snapshot().contains(where: { $0.requestId == "new" && $0.type == "diary_failed" }) { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(fixture.events.snapshot().last?.code == "inference_memory_insufficient")
    #expect(await fixture.runtime.diaryGenerationCount == 0)
    _ = try await fixture.memory.insertDiaryIfAbsent(characterID: "test", localDate: day.key,
        draft: .init(title: "하루", body: "산책했어요."))
    await fixture.controller.requestDiary(requestId: "existing", localDate: day.key)
    for _ in 0..<1000 {
        if fixture.events.snapshot().contains(where: { $0.requestId == "existing" }) { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(fixture.events.snapshot().last?.type == "diary_completed")
    #expect(probe.count(.diary) == 1)
}

@Test func pressureAfterAdmissionDoesNotInterruptTheRunningAnswer() async throws {
    let probe = InferenceAdmissionProbe()
    let fixture = try ChatControllerFixture(checkInferenceAdmission: probe.check)
    defer { fixture.remove() }
    await fixture.controller.initialize()
    await fixture.runtime.setHolding(true)
    let send = Task { await fixture.controller.send(json: fixture.request("running", "안녕")) }
    for _ in 0..<1000 {
        if await fixture.runtime.generationCount > 0 { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(await fixture.runtime.generationCount == 1)
    probe.block([.dialogue])
    await fixture.runtime.finishStream()
    await send.value
    #expect(try fixture.store.load()?.chatTurns.last?.status == .completed)
    #expect(probe.count(.dialogue) == 1)
    await fixture.controller.send(json: fixture.request("next", "다음 질문"))
    #expect(fixture.events.snapshot().last?.code == "inference_memory_insufficient")
    #expect(await fixture.runtime.generationCount == 1)
}
