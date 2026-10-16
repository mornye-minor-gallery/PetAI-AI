import Foundation
import Testing
@testable import EdgeLLM

private func compactingConfiguration(enabled: Bool = true) -> SLMConfiguration {
    let base = SLMConfiguration.production
    return .init(id: "compaction-test", memory: base.memory, generation: base.generation,
        persona: base.persona, runtimeSafety: base.runtimeSafety,
        dialogueBudget: .init(memoryTokens: 40, contextTokens: 1800, outputTokens: 100,
            limits: .init(fixedTokens: 1500, loreTokens: 80, topicTokens: 80, stateTokens: 300,
                          questionTokens: 100, questionCharacters: 500),
            contextPolicy: .init(summaryEnabled: enabled, summaryTokens: 120, recentTurns: 3)))
}

@Test func memoryDeferredSummaryKeepsOriginalsAndRetriesBeforeAcceptingAnotherQuestion() async throws {
    let admission = InferenceAdmissionProbe()
    admission.block([.summary])
    let fixture = try ChatControllerFixture(configuration: compactingConfiguration(),
        checkInferenceAdmission: { try admission.check($0) })
    defer { fixture.remove() }
    await fixture.runtime.setResponse("save(P=0,E=0)\n" + String(repeating: "말", count: 90))
    await fixture.controller.initialize()
    for index in 0..<14 {
        await fixture.controller.send(json: fixture.request("r\(index)", "질문 \(index)"))
        if fixture.events.snapshot().contains(where: { $0.code == "inference_memory_insufficient" }) { break }
    }
    let before = try #require(try fixture.store.load())
    #expect(before.chatTurns.count > 3)
    #expect(before.summary == nil)
    #expect(await fixture.runtime.summaryGenerationCount == 0)
    #expect(fixture.events.snapshot().last?.type == "context_ready")
    await fixture.controller.send(json: fixture.request("blocked", "새 질문"))
    #expect(fixture.events.snapshot().last?.code == "inference_memory_insufficient")
    #expect(try fixture.store.load()?.chatTurns.count == before.chatTurns.count)
    admission.block([])
    await fixture.controller.send(json: fixture.request("retry", "다시 질문"))
    #expect(await fixture.runtime.summaryGenerationCount > 0)
    #expect(try fixture.store.load()?.chatTurns.last?.requestID == "retry")
    #expect(!fixture.events.snapshot().contains { $0.code == "summary_generation_failed" })
}

@Test func controllerCompactsAndSearchExcludesOnlyTheRetainedOriginalRequests() async throws {
    let fixture = try ChatControllerFixture(configuration: compactingConfiguration())
    defer { fixture.remove() }
    await fixture.runtime.setResponse("save(P=0,E=0)\n" + String(repeating: "말", count: 90))
    await fixture.controller.initialize()
    for index in 0..<14 { await fixture.controller.send(json: fixture.request("r\(index)", "질문 \(index)")) }
    #expect(await fixture.runtime.summaryGenerationCount > 0)
    let saved = try #require(try fixture.store.load())
    #expect(saved.summary != nil)
    let expected = Set(saved.chatTurns.map(\.requestID)).union(["next"])
    await fixture.controller.send(json: fixture.request("next", "다음 질문"))
    #expect(await fixture.memory.lastExcluded == expected)
    #expect(await fixture.runtime.prefilledInputs.count > 0)
    let events = fixture.events.snapshot()
    let start = try #require(events.firstIndex { $0.type == "context_compacting" })
    let id = try #require(events[start].requestId)
    let completion = try #require(events.firstIndex { $0.type == "completed" && $0.requestId == id })
    let ready = try #require(events.firstIndex { $0.type == "context_ready" && $0.requestId == id })
    #expect(start < completion && completion < ready)
}

@Test func summaryGenerationFailureKeepsConversationAvailableWithoutASummary() async throws {
    let fixture = try ChatControllerFixture(configuration: compactingConfiguration())
    defer { fixture.remove() }
    await fixture.runtime.setResponse("save(P=0,E=0)\n" + String(repeating: "말", count: 90))
    await fixture.runtime.failSummary(with: CocoaError(.fileReadCorruptFile))
    await fixture.controller.initialize()
    for index in 0..<14 { await fixture.controller.send(json: fixture.request("r\(index)", "질문 \(index)")) }
    #expect(await fixture.runtime.summaryGenerationCount > 0)
    let saved = try #require(try fixture.store.load())
    #expect(saved.summary == nil)
    #expect(fixture.events.snapshot().contains { $0.type == "context_warning" && $0.code == "summary_generation_failed" })
    #expect(fixture.events.snapshot().last?.type == "context_ready" || fixture.events.snapshot().last?.type == "completed")
}

@Test func disabledSummaryUsesCompactionWithoutSummaryInference() async throws {
    let fixture = try ChatControllerFixture(configuration: compactingConfiguration(enabled: false))
    defer { fixture.remove() }
    await fixture.runtime.setResponse("save(P=0,E=0)\n" + String(repeating: "말", count: 90))
    await fixture.controller.initialize()
    for index in 0..<14 { await fixture.controller.send(json: fixture.request("r\(index)", "질문 \(index)")) }
    #expect(await fixture.runtime.summaryGenerationCount == 0)
    #expect(await fixture.runtime.prefilledInputs.count > 0)
    let saved = try #require(try fixture.store.load())
    #expect(saved.summary == nil)
}

@Test func brokenEngineDuringSummaryDoesNotTakeRecentOnlyFallback() async throws {
    let fixture = try ChatControllerFixture(configuration: compactingConfiguration())
    defer { fixture.remove() }
    await fixture.runtime.setResponse("save(P=0,E=0)\n" + String(repeating: "말", count: 90))
    await fixture.runtime.failSummary(with: RuntimeError.engineRequiresReload)
    await fixture.controller.initialize()
    for index in 0..<14 {
        await fixture.controller.send(json: fixture.request("r\(index)", "질문 \(index)"))
        if fixture.events.snapshot().contains(where: { $0.type == "context_failed" }) { break }
    }
    #expect(await fixture.runtime.summaryGenerationCount == 1)
    #expect(await fixture.runtime.prefilledInputs.isEmpty)
    #expect(!fixture.events.snapshot().contains { $0.type == "context_warning" })
    #expect(fixture.events.snapshot().contains { $0.type == "context_failed" })
}

@Test func overLimitQuestionIsRejectedBeforeDurableAdmissionAndInference() async throws {
    let fixture = try ChatControllerFixture()
    defer { fixture.remove() }
    await fixture.controller.initialize()
    await fixture.controller.send(json: fixture.request("too-long", String(repeating: "가", count: 501)))
    #expect(await fixture.runtime.generationCount == 0)
    #expect(await fixture.memory.classificationCount == 0)
    #expect(try fixture.store.load()?.chatTurns.isEmpty ?? true)
    #expect(fixture.events.snapshot().last?.code == "input_limit_exceeded")
}

@Test func overLimitTokensAreRejectedWithoutCuttingTheQuestion() async throws {
    let fixture = try ChatControllerFixture()
    defer { fixture.remove() }
    await fixture.controller.initialize()
    await fixture.controller.send(json: fixture.request("token-limit", String(repeating: "가", count: 301)))
    #expect(await fixture.runtime.generationCount == 0)
    #expect(try fixture.store.load()?.chatTurns.isEmpty ?? true)
    #expect(fixture.events.snapshot().last?.code == "input_limit_exceeded")
}

@Test func failedNativePreparationKeepsTheOldContextAndTheCompletedReply() async throws {
    let fixture = try ChatControllerFixture(configuration: compactingConfiguration())
    defer { fixture.remove() }
    await fixture.runtime.setResponse("save(P=0,E=0)\n" + String(repeating: "말", count: 90))
    await fixture.runtime.failPrefill(with: CocoaError(.fileWriteOutOfSpace))
    await fixture.controller.initialize()
    for index in 0..<14 {
        await fixture.controller.send(json: fixture.request("r\(index)", "질문 \(index)"))
        if fixture.events.snapshot().contains(where: { $0.type == "context_failed" }) { break }
    }
    let saved = try #require(try fixture.store.load())
    #expect(saved.summary == nil)
    #expect(saved.chatTurns.count > 3)
    let last = try #require(saved.chatTurns.last)
    #expect(last.status == .completed)
    #expect(fixture.events.snapshot().contains { $0.type == "completed" && $0.requestId == last.requestID })
    #expect(fixture.events.snapshot().last?.type == "context_failed")
    await fixture.controller.send(json: fixture.request("blocked", "다음 질문"))
    #expect(fixture.events.snapshot().last?.code == "runtime_not_ready")
}

@Test func restoredFiniteHistoryIsPreservedWhenTheProductUsesTokenCompaction() async throws {
    let fixture = try ChatControllerFixture()
    defer { fixture.remove() }
    var old = RoutedPersonaSessionContext(maximumTurnCount: 20)
    for index in 0..<20 { old.appendExchange(userMessage: "질문 \(index)", assistantMessage: "답변 \(index)") }
    try fixture.store.save(old)
    await fixture.controller.initialize()
    await fixture.controller.send(json: fixture.request("new", "다음 질문"))
    let saved = try #require(try fixture.store.load())
    #expect(saved.chatTurns.count == 21)
    #expect(saved.chatTurns.first?.userMessage == "질문 0")
}

@Test func currentInputOverflowIsRepairedBeforeDecodeAndConcurrentCancelIsPreserved() async throws {
    let configuration = compactingConfiguration()
    let fixture = try ChatControllerFixture(configuration: configuration)
    defer { fixture.remove() }
    var old = RoutedPersonaSessionContext()
    for index in 0..<9 { old.appendExchange(userMessage: "질문 \(index)" + String(repeating: "질", count: 40),
                                          assistantMessage: String(repeating: "답", count: 90)) }
    try fixture.store.save(old)
    await fixture.runtime.usePreparationBudget(configuration.dialogueBudget)
    await fixture.runtime.holdPrefills()
    await fixture.controller.initialize()
    let send = Task { await fixture.controller.send(json: fixture.request("overflow", "새 질문")) }
    await fixture.runtime.waitForPrefill()
    await fixture.controller.send(json: fixture.request("duplicate", "동시 질문"))
    #expect(fixture.events.snapshot().last?.code == "runtime_not_ready")
    #expect(try fixture.store.load()?.chatTurns.contains { $0.requestID == "duplicate" } == false)
    await fixture.controller.cancel(requestID: "overflow")
    await fixture.runtime.finishPrefill()
    await send.value
    #expect(await fixture.runtime.generationCount == 0)
    #expect(fixture.events.snapshot().last?.type == "cancelled")
    let saved = try #require(try fixture.store.load())
    #expect(saved.chatTurns.last?.requestID == "overflow")
    #expect(saved.chatTurns.last?.status == .cancelled)
}

@Test func personaDisabledModeStillUsesTheSharedContextAndCompaction() async throws {
    let fixture = try ChatControllerFixture(configuration: compactingConfiguration(), personaEnabled: false)
    defer { fixture.remove() }
    await fixture.runtime.setResponse("save(P=0,E=0)\n" + String(repeating: "말", count: 90))
    await fixture.controller.initialize()
    for index in 0..<18 { await fixture.controller.send(json: fixture.request("r\(index)", "질문 \(index)")) }
    #expect(await fixture.runtime.summaryGenerationCount > 0)
    #expect(await fixture.runtime.prefilledInputs.count > 0)
}
