import Foundation
import XCTest
@testable import EdgeLLM

final class CurrentTimeToolTests: XCTestCase {
    func testSuppliedSelectorRoutesClockAndPreservesTheMLPGate() throws {
        let artifacts = try makeOwnedRouterFixture()
        let pipeline = try NativeToolRouterArtifactRegistry(manifestSHA256: artifacts.digest) { artifacts.files[$0] }.load()
        let cases = try clockRoutingCases()
        for row in cases {
            let probability: Float
            switch try pipeline.actionability.classify(row.embedding) {
            case .call(let value), .noCall(let value): probability = value
            }
            XCTAssertEqual(probability, row.probability, accuracy: 0.00001)
            XCTAssertEqual(try pipeline.selector.route(row.embedding), row.selector)
            XCTAssertEqual(try pipeline.route(row.embedding), row.pipeline)
        }
    }

    func testClockRunsThroughTheSuppliedRouterWithoutArgumentInference() async throws {
        let artifacts = try makeOwnedRouterFixture()
        let registry = NativeToolRouterArtifactRegistry(manifestSHA256: artifacts.digest) { artifacts.files[$0] }
        let fixture = try ChatControllerFixture(toolRouterArtifacts: registry)
        defer { fixture.remove() }
        let row = try XCTUnwrap(clockRoutingCases().first)
        await fixture.memory.setClassificationEmbedding(row.embedding)
        await fixture.controller.initialize()
        await fixture.controller.send(json: fixture.request("routed-clock", row.utterance))
        let saved = try XCTUnwrap(fixture.store.load()?.chatTurns.last)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertTrue(saved.assistantMessage.hasPrefix("지금은 "))
        let generations = await fixture.runtime.generationCount
        let argumentGenerations = await fixture.runtime.functionCallCount
        let embeddings = await fixture.memory.classificationCount
        XCTAssertEqual(generations, 0)
        XCTAssertEqual(argumentGenerations, 0)
        XCTAssertEqual(embeddings, 1)
    }

    func testClockCallHasNoArgumentsAndRejectsExtraFields() throws {
        let parser = NativeToolProposalParser()
        let proposal = try parser.parse(.init(name: "get_current_time", argumentsJSON: "{}"),
            selectedTool: .getCurrentTime, requestID: "clock")
        XCTAssertEqual(proposal.arguments, .getCurrentTime)
        let validated = try NativeToolProposalValidator().validate(proposal)
        XCTAssertEqual(validated.arguments, .getCurrentTime)
        XCTAssertThrowsError(try parser.parse(.init(name: "get_current_time", argumentsJSON: #"{"hour":7}"#),
            selectedTool: .getCurrentTime, requestID: "clock"))
        XCTAssertTrue(NativeToolAccessPolicy([]).allowedTools.contains(.getCurrentTime))
        XCTAssertFalse(NativeToolKind.getCurrentTime.requiresConfirmation)
        XCTAssertTrue(NativeToolKind.createAlarm.requiresConfirmation)
    }

    func testClockUsesExecutionTimeAndFormatsLocalTime() throws {
        let instant = Date(timeIntervalSince1970: 1_759_431_020) // 2025-10-02T18:50:20Z
        let cases = [("Asia/Seoul", "지금은 오전 3시 50분이야."),
                     ("America/New_York", "지금은 오후 2시 50분이야.")]
        for (zone, expected) in cases {
            let proposal = clockProposal("clock-\(zone)", zone: zone)
            let data = try CurrentTimeTool().execute(proposal, now: instant)
            let result = NativeToolExecutionEnvelope(requestID: proposal.requestID, tool: .getCurrentTime,
                status: .success, data: data)
            // The result's zone, not the formatter host's zone, owns the displayed clock.
            let text = try NativeToolResultFormatter(calendar: utcCalendar()).visibleText(for: result)
            XCTAssertEqual(text, expected)
            guard case .object(let fields) = data else { return XCTFail("Expected a clock result") }
            XCTAssertEqual(fields["timeZoneIdentifier"], .string(zone))
            XCTAssertEqual(fields["currentDateTime"], .string("2025-10-02T18:50:20Z"))
        }
    }

    func testClockFormatterHandlesMidnightAndNoonAndRejectsInvalidResults() throws {
        for (stamp, expected) in [("2026-10-03T00:00:00Z", "지금은 오전 12시야."),
                                  ("2026-10-03T12:00:00Z", "지금은 오후 12시야.")] {
            let result = NativeToolExecutionEnvelope(requestID: "clock", tool: .getCurrentTime, status: .success,
                data: .object(["currentDateTime": .string(stamp), "timeZoneIdentifier": .string("GMT")]))
            XCTAssertEqual(try NativeToolResultFormatter().visibleText(for: result), expected)
        }
        for data: JSONValue in [.null,
            .object(["currentDateTime": .string("invalid"), "timeZoneIdentifier": .string("GMT")]),
            .object(["currentDateTime": .string("2026-10-03T12:00:00Z"), "timeZoneIdentifier": .string("invalid-zone")])] {
            XCTAssertThrowsError(try NativeToolResultFormatter().visibleText(for: .init(
                requestID: "clock", tool: .getCurrentTime, status: .success, data: data)))
        }
        XCTAssertThrowsError(try CurrentTimeTool().execute(clockProposal("bad-zone", zone: "invalid-zone")))
        XCTAssertThrowsError(try CurrentTimeTool().execute(.init(requestID: "mismatch", tool: .createAlarm,
            timeZoneIdentifier: "GMT", arguments: .getCurrentTime)))
    }

    func testClockProposalSkipsGemmaAndPromptLoading() async throws {
        let generator = ClockForbiddenGenerator()
        let coordinator = NativeToolProposalCoordinator { _ in .null }
        let harness = NativeToolProposalHarness(router: ClockOnlyRouter(),
            promptRegistry: .init { _ in XCTFail("Clock must not load a generation prompt"); return nil },
            coordinator: coordinator, generator: generator)
        let outcome = try await harness.prepare(requestID: "clock", userMessage: "지금 몇 시야?",
            promptContext: .init(now: Date(), calendar: .current), allowedTools: [.getCurrentTime])
        guard case .proposal(let draft, let validated, let event) = outcome else {
            return XCTFail("Expected a parameterless clock proposal")
        }
        XCTAssertEqual(draft.arguments, .getCurrentTime)
        XCTAssertEqual(validated.arguments, .getCurrentTime)
        XCTAssertEqual(event.state, .proposalReady)
        let calls = await generator.calls
        XCTAssertEqual(calls, 0)
    }

    func testUnconfirmedClockExecutesOnceAndKeepsFailuresObservable() async throws {
        let executor = ClockExecutionCounter()
        let coordinator = NativeToolProposalCoordinator { await executor.execute($0) }
        try await coordinator.register(clockProposal("clock"))
        let result = try await coordinator.executeWithoutConfirmation(requestID: "clock")
        XCTAssertEqual(result.status, .success)
        let snapshot = await coordinator.snapshot(requestID: "clock")
        XCTAssertEqual(snapshot?.state, .completed)
        XCTAssertEqual(snapshot?.hasExecuted, true)
        do {
            _ = try await coordinator.executeWithoutConfirmation(requestID: "clock")
            XCTFail("A request cannot execute twice")
        } catch { XCTAssertEqual(error as? NativeToolCoordinatorError, .requestAlreadyExecuted) }
        let count = await executor.count
        XCTAssertEqual(count, 1)

        let failed = NativeToolProposalCoordinator { _ in throw NativeToolErrorCode.dataUnavailable }
        try await failed.register(clockProposal("failure"))
        let failure = try await failed.executeWithoutConfirmation(requestID: "failure")
        XCTAssertEqual(failure.status, .failure)
        XCTAssertEqual(failure.errorCode, .dataUnavailable)
        let failedSnapshot = await failed.snapshot(requestID: "failure")
        XCTAssertEqual(failedSnapshot?.state, .failed)
    }

    func testUnconfirmedExecutionCannotBypassAlarmConfirmationOrCancellation() async throws {
        let executor = ClockExecutionCounter()
        let coordinator = NativeToolProposalCoordinator { await executor.execute($0) }
        try await coordinator.register(.init(requestID: "alarm", tool: .createAlarm,
            timeZoneIdentifier: "GMT", arguments: .createAlarm(date: Date(), label: "알람")))
        do {
            _ = try await coordinator.executeWithoutConfirmation(requestID: "alarm")
            XCTFail("Alarms must still require confirmation")
        } catch { XCTAssertEqual(error as? NativeToolCoordinatorError, .invalidTransition) }
        _ = try await coordinator.cancel(requestID: "alarm")
        try await coordinator.register(clockProposal("cancelled-clock"))
        _ = try await coordinator.cancel(requestID: "cancelled-clock")
        do {
            _ = try await coordinator.executeWithoutConfirmation(requestID: "cancelled-clock")
            XCTFail("A cancelled clock request must not execute")
        } catch { XCTAssertEqual(error as? NativeToolCoordinatorError, .invalidTransition) }
        let count = await executor.count
        XCTAssertEqual(count, 0)
    }

    func testClockCompletesInSharedControllerWithoutPlatformToolsOrInference() async throws {
        let fixture = try ChatControllerFixture()
        defer { fixture.remove() }
        await fixture.controller.initialize()
        await fixture.controller.useClockRouter()
        await fixture.controller.send(json: fixture.request("clock", "지금 몇 시야?"))
        let saved = try XCTUnwrap(fixture.store.load()?.chatTurns.last)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertTrue(saved.assistantMessage.hasPrefix("지금은 "))
        XCTAssertTrue(saved.assistantMessage.hasSuffix("이야.") || saved.assistantMessage.hasSuffix("야."))
        XCTAssertTrue(fixture.events.snapshot().contains {
            $0.type == "completed" && $0.presentation == .tool && $0.text == saved.assistantMessage
        })
        XCTAssertFalse(fixture.events.snapshot().contains { $0.type == "error" })
        let counts = await (fixture.runtime.generationCount, fixture.runtime.functionCallCount,
                            fixture.runtime.checkpointCount, fixture.memory.writeCount)
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(counts.3, 0)
    }
}

private struct ClockRoutingCase {
    let utterance: String
    let probability: Float
    let selector: NativeToolRoute
    let pipeline: NativeToolRoute
    let embedding: [Float]
}

private func clockRoutingCases() throws -> [ClockRoutingCase] {
    // 학습 가중치를 재배포하지 않고 실행 의도 판정·시각 선택의 순서를 검증하는 직접 작성 벡터다.
    let clockIndex = try XCTUnwrap(NativeToolKind.allCases.firstIndex(of: .getCurrentTime))
    func vector(_ actionability: Float, _ clock: Float, unmatched: Float = 0) -> [Float] {
        var values = [Float](repeating: 0, count: NativeToolRouterArtifactRegistry.expectedDimension)
        values[0] = actionability
        values[clockIndex] = clock
        values[32] = unmatched
        return values
    }
    return [
        .init(utterance: "지금 몇 시인지 확인 좀 부탁해.", probability: 0.9933071491,
              selector: .tool(.getCurrentTime), pipeline: .tool(.getCurrentTime), embedding: vector(1, 2)),
        .init(utterance: "현재 시간이 궁금해, 알려줘.", probability: 0.0066928509,
              selector: .tool(.getCurrentTime), pipeline: .normal, embedding: vector(0, 2)),
        .init(utterance: "지금은 몇 시니?", probability: 0.9933071491,
              selector: .normal, pipeline: .normal, embedding: vector(1, 0, unmatched: 2)),
    ]
}

private func clockProposal(_ id: String, zone: String = "GMT") -> ValidatedToolProposal {
    .init(requestID: id, tool: .getCurrentTime, timeZoneIdentifier: zone, arguments: .getCurrentTime)
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private struct ClockOnlyRouter: NativeToolRouting {
    func route(_ utterance: String) -> NativeToolRoute { .tool(.getCurrentTime) }
}

private extension ChatSessionController {
    func useClockRouter() { nativeToolRouter = ClockOnlyRouter() }
}

private actor ClockForbiddenGenerator: NativeToolProposalGenerating {
    var calls = 0
    func generateFunctionCall(_ request: NativeToolGenerationRequest) throws -> NativeToolFunctionCall {
        calls += 1
        throw RuntimeError.runtimeBusy
    }
}

private actor ClockExecutionCounter {
    var count = 0
    func execute(_ proposal: ValidatedToolProposal) -> JSONValue {
        count += 1
        return .null
    }
}
