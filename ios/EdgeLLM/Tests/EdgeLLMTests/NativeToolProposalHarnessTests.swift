import Foundation
import Testing
@testable import EdgeLLM

@Test
func productPromptRegistryLoadsAndVerifiesEveryToolPrompt() throws {
    let registry = NativeToolPromptRegistry()

    for tool in NativeToolKind.allCases {
        let prompt = try registry.prompt(for: tool)
        #expect(prompt.tool == tool)
        #expect(prompt.source.contains(tool.rawValue))
        #expect(
            prompt.sourceSHA256
                == NativeToolPromptRegistry.expectedChecksum(for: tool)
        )
    }
}

@Test
func productPromptRegistryRejectsModifiedPromptBytes() {
    let registry = NativeToolPromptRegistry { _ in
        Data("modified".utf8)
    }

    do {
        _ = try registry.prompt(for: .createAlarm)
        Issue.record("Expected prompt checksum failure")
    } catch let error as NativeToolPromptRegistryError {
        guard case .checksumMismatch(let tool, _, _) = error else {
            Issue.record("Unexpected registry error: \(error)")
            return
        }
        #expect(tool == .createAlarm)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func renderedProductPromptAddsOnlyDeviceOwnedTimeContext() throws {
    let prompt = try NativeToolPromptRegistry().prompt(for: .createTimer)
    let rendered = prompt.rendered(
        with: NativeToolPromptContext(
            currentDate: "2026-08-03",
            currentDateTime: "2026-08-03T14:30",
            timeZoneIdentifier: "Asia/Seoul"
        )
    )

    #expect(rendered.hasPrefix(prompt.source))
    #expect(rendered.contains("currentDate: 2026-08-03"))
    #expect(rendered.contains("currentDateTime: 2026-08-03T14:30"))
    #expect(rendered.contains("timeZoneIdentifier: Asia/Seoul"))
}

@Test
func proposalParserAcceptsAllSevenCanonicalToolCalls() throws {
    let parser = NativeToolProposalParser()
    let cases: [(NativeToolKind, String, NativeToolArguments)] = [
        (
            .getStepCount,
            #"{"startDate":"2026-08-03","endDate":"2026-08-03","aggregation":"total"}"#,
            .getStepCount(
                StepCountArguments(
                    startDate: "2026-08-03",
                    endDate: "2026-08-03",
                    aggregation: .total
                )
            )
        ),
        (
            .createAlarm,
            #"{"date":"2026-08-04","hour":7,"minute":0,"label":"운동"}"#,
            .createAlarm(
                CreateAlarmArguments(
                    date: "2026-08-04",
                    hour: 7,
                    minute: 0,
                    label: "운동"
                )
            )
        ),
        (.listAlarms, "{}", .listAlarms),
        (
            .createTimer,
            #"{"durationSeconds":600,"label":"차 마시기"}"#,
            .createTimer(
                CreateTimerArguments(
                    durationSeconds: 600,
                    label: "차 마시기"
                )
            )
        ),
        (
            .scheduleLocalNotification,
            #"{"dateTime":"2026-08-04T15:00","title":"물","body":"물 마실 시간이에요"}"#,
            .scheduleLocalNotification(
                LocalNotificationArguments(
                    dateTime: "2026-08-04T15:00",
                    title: "물",
                    body: "물 마실 시간이에요"
                )
            )
        ),
        (
            .getCalendarEvents,
            #"{"startDate":"2026-08-04","endDate":"2026-08-04"}"#,
            .getCalendarEvents(
                CalendarQueryArguments(
                    startDate: "2026-08-04",
                    endDate: "2026-08-04"
                )
            )
        ),
        (
            .createCalendarEvent,
            #"{"title":"멘토링","startDateTime":"2026-08-04T15:00","location":"센터"}"#,
            .createCalendarEvent(
                CalendarEventArguments(
                    title: "멘토링",
                    startDateTime: "2026-08-04T15:00",
                    location: "센터"
                )
            )
        ),
    ]

    for (tool, json, expected) in cases {
        let proposal = try parser.parse(
            NativeToolFunctionCall(
                name: tool.rawValue,
                argumentsJSON: json
            ),
            selectedTool: tool,
            requestID: "request-\(tool.rawValue)"
        )
        #expect(proposal.tool == tool)
        #expect(proposal.arguments == expected)
    }
}

@Test
func proposalParserAllowsExplicitNullForOptionalCalendarFields() throws {
    let proposal = try NativeToolProposalParser().parse(
        NativeToolFunctionCall(
            name: NativeToolKind.createCalendarEvent.rawValue,
            argumentsJSON:
                #"{"title":"멘토링","startDateTime":"2026-08-04T15:00","endDateTime":null,"location":null}"#
        ),
        selectedTool: .createCalendarEvent,
        requestID: "calendar-null"
    )

    #expect(
        proposal.arguments
            == .createCalendarEvent(
                CalendarEventArguments(
                    title: "멘토링",
                    startDateTime: "2026-08-04T15:00"
                )
            )
    )
}

@Test
func proposalParserFailsClosedOnWrongToolExtraFieldsAndProse() {
    let parser = NativeToolProposalParser()
    let cases = [
        NativeToolFunctionCall(
            name: NativeToolKind.createAlarm.rawValue,
            argumentsJSON: "{}"
        ),
        NativeToolFunctionCall(
            name: NativeToolKind.createTimer.rawValue,
            argumentsJSON:
                #"{"durationSeconds":60,"label":"차","extra":true}"#
        ),
        NativeToolFunctionCall(
            name: NativeToolKind.createTimer.rawValue,
            argumentsJSON: "```json\n{}\n```"
        ),
    ]

    for call in cases {
        do {
            _ = try parser.parse(
                call,
                selectedTool: .createTimer,
                requestID: "invalid"
            )
            Issue.record("Expected fail-closed parser rejection")
        } catch {
            #expect(error is NativeToolProposalParserError)
        }
    }
}

@Test
func proposalParserRejectsBooleanWhereIntegerIsRequired() {
    do {
        _ = try NativeToolProposalParser().parse(
            NativeToolFunctionCall(
                name: NativeToolKind.createTimer.rawValue,
                argumentsJSON:
                    #"{"durationSeconds":true,"label":"차"}"#
            ),
            selectedTool: .createTimer,
            requestID: "boolean-int"
        )
        Issue.record("Expected boolean rejection")
    } catch {
        #expect(error is NativeToolProposalParserError)
    }
}

private actor ProposalGeneratorStub: NativeToolProposalGenerating {
    private let call: NativeToolFunctionCall
    private var requests: [NativeToolGenerationRequest] = []

    init(call: NativeToolFunctionCall) {
        self.call = call
    }

    func generateFunctionCall(
        _ request: NativeToolGenerationRequest
    ) async throws -> NativeToolFunctionCall {
        requests.append(request)
        return call
    }

    func receivedRequests() -> [NativeToolGenerationRequest] {
        requests
    }
}

@Test
func proposalHarnessSkipsGemmaForNormalAndConflictRoutes() async throws {
    let generator = ProposalGeneratorStub(
        call: NativeToolFunctionCall(
            name: NativeToolKind.createTimer.rawValue,
            argumentsJSON: "{}"
        )
    )
    let coordinator = NativeToolProposalCoordinator { _ in .null }
    let harness = NativeToolProposalHarness(
        coordinator: coordinator,
        generator: generator
    )
    let context = NativeToolPromptContext(
        currentDate: "2026-08-03",
        currentDateTime: "2026-08-03T12:00",
        timeZoneIdentifier: "Asia/Seoul"
    )

    let normal = try await harness.prepare(
        requestID: "normal",
        userMessage: "오늘 만 보 걸었어",
        promptContext: context
    )
    let conflict = try await harness.prepare(
        requestID: "conflict",
        userMessage: "내일 일정 보여 주고 7시 알람도 맞춰 줘",
        promptContext: context
    )
    let requests = await generator.receivedRequests()

    #expect(normal == .normal)
    #expect(
        conflict
            == .conflict(
                message: NativeToolProposalHarness.conflictMessage,
                tools: [.createAlarm, .getCalendarEvents]
            )
    )
    #expect(requests.isEmpty)
}

@Test
func proposalHarnessRegistersOneValidatedProposalWithoutExecuting() async throws {
    let generator = ProposalGeneratorStub(
        call: NativeToolFunctionCall(
            name: NativeToolKind.createAlarm.rawValue,
            argumentsJSON:
                #"{"date":"2026-08-04","hour":7,"minute":0,"label":"운동"}"#
        )
    )
    let executionCounter = ExecutionCounterForHarness()
    let coordinator = NativeToolProposalCoordinator { _ in
        await executionCounter.increment()
        return .null
    }
    let validator = NativeToolProposalValidator(
        now: localDateForHarness(2026, 8, 3, 12),
        calendar: seoulCalendarForHarness()
    )
    let harness = NativeToolProposalHarness(
        validator: validator,
        coordinator: coordinator,
        generator: generator
    )
    let outcome = try await harness.prepare(
        requestID: "alarm-proposal",
        userMessage: "내일 아침 7시에 운동 알람 맞춰 줘",
        promptContext: NativeToolPromptContext(
            currentDate: "2026-08-03",
            currentDateTime: "2026-08-03T12:00",
            timeZoneIdentifier: "Asia/Seoul"
        )
    )

    guard case .proposal(let draft, let proposal, let event) = outcome else {
        Issue.record("Expected validated proposal")
        return
    }
    let requests = await generator.receivedRequests()
    let executions = await executionCounter.value()
    let snapshot = await coordinator.snapshot(requestID: "alarm-proposal")

    #expect(draft.requestID == "alarm-proposal")
    #expect(draft.tool == .createAlarm)
    #expect(proposal.tool == .createAlarm)
    #expect(event.state == .proposalReady)
    #expect(event.requestID == "alarm-proposal")
    #expect(requests.count == 1)
    #expect(requests.first?.selectedTool == .createAlarm)
    #expect(requests.first?.reasoningEnabled == false)
    #expect(requests.first?.systemPrompt.contains("currentDate: 2026-08-03") == true)
    #expect(executions == 0)
    #expect(snapshot?.state == .proposalReady)
}

private actor ExecutionCounterForHarness {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int { count }
}

private func seoulCalendarForHarness() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return calendar
}

private func localDateForHarness(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int
) -> Date {
    seoulCalendarForHarness().date(
        from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        )
    )!
}
