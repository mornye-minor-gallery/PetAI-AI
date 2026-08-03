import Foundation
import Testing
@testable import EdgeLLM

@Test
func stepCountResultFormatterProducesUserVisibleKoreanText() {
    let formatter = NativeToolResultFormatter()
    let envelope = NativeToolExecutionEnvelope(
        requestID: "steps-1",
        tool: .getStepCount,
        status: .success,
        data: .object([
            "aggregation": .string("total"),
            "totalSteps": .number(12_345),
        ])
    )

    #expect(
        formatter.visibleText(for: envelope)
            == "해당 기간에는 총 12345걸음을 걸었어요."
    )
}

@Test
func stepCountDataPolicyDistinguishesZeroFromUnreadableData() throws {
    #expect(try StepCountDataPolicy.totalSteps(from: 0) == 0)
    #expect(try StepCountDataPolicy.dailySteps(from: [120, nil, 80])
        == [120, 0, 80])

    #expect(throws: NativeToolErrorCode.dataUnavailable) {
        try StepCountDataPolicy.totalSteps(from: nil)
    }
    #expect(throws: NativeToolErrorCode.dataUnavailable) {
        try StepCountDataPolicy.dailySteps(from: [nil, nil])
    }
}

@Test
func stepCountFormatterDoesNotClaimPermissionWasDenied() {
    let envelope = NativeToolExecutionEnvelope(
        requestID: "steps-unavailable",
        tool: .getStepCount,
        status: .failure,
        errorCode: .dataUnavailable
    )

    #expect(
        NativeToolResultFormatter().visibleText(for: envelope)
            == "걸음 수 데이터를 확인할 수 없어요. 건강 앱에서 접근 권한과 데이터 상태를 확인해 주세요."
    )
}

private func seoulCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return calendar
}

private func localDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0
) -> Date {
    seoulCalendar().date(
        from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
    )!
}

private func validatedTimer(
    requestID: String,
    seconds: Int = 600
) -> ValidatedToolProposal {
    ValidatedToolProposal(
        requestID: requestID,
        tool: .createTimer,
        timeZoneIdentifier: "Asia/Seoul",
        arguments: .createTimer(
            durationSeconds: seconds,
            label: "차 마시기"
        )
    )
}

@Test
func koreanRouterSelectsEverySupportedTool() {
    let router = KoreanNativeToolRouter()
    let cases: [(String, NativeToolKind)] = [
        ("오늘 몇 걸음 걸었어?", .getStepCount),
        ("내일 아침 7시에 운동 알람 맞춰 줘", .createAlarm),
        ("내 알람 목록 보여 줘", .listAlarms),
        ("10분 타이머 시작해 줘", .createTimer),
        ("오후 3시에 물 마시라고 알려 줘", .scheduleLocalNotification),
        ("내일 일정 알려 줘", .getCalendarEvents),
        ("내일 3시에 멘토링 일정 잡아 줘", .createCalendarEvent),
    ]

    for (utterance, tool) in cases {
        #expect(router.route(utterance) == .tool(tool))
    }
}

@Test
func koreanRouterKeepsStatementsAndCasualConversationOnChatPath() {
    let router = KoreanNativeToolRouter()
    let cases = [
        "오늘 만 보 걸었어",
        "알람 소리 너무 싫어",
        "내일 약속이 있어",
        "요즘 타이머를 자주 써",
        "안녕, 오늘 기분 어때?",
    ]

    for utterance in cases {
        #expect(router.route(utterance) == .normal)
    }
}

@Test
func koreanRouterRejectsMultipleToolIntentsAsConflict() {
    let route = KoreanNativeToolRouter().route(
        "내일 일정을 보여 주고 7시 알람도 맞춰 줘"
    )

    #expect(
        route == .conflict([.createAlarm, .getCalendarEvents])
    )
}

@Test
func validatorMapsInclusiveRangesToExclusiveNativeUpperBounds() throws {
    let validator = NativeToolProposalValidator(
        now: localDate(2026, 8, 3, 12),
        calendar: seoulCalendar()
    )
    let proposal = NativeToolProposal(
        requestID: "steps-1",
        tool: .getStepCount,
        arguments: .getStepCount(
            StepCountArguments(
                startDate: "2026-08-01",
                endDate: "2026-08-03",
                aggregation: .daily
            )
        )
    )

    let validated = try validator.validate(proposal)
    guard case .getStepCount(
        let start,
        let inclusiveEnd,
        let exclusiveEnd,
        let aggregation
    ) = validated.arguments else {
        Issue.record("Expected step-count arguments")
        return
    }

    #expect(start == localDate(2026, 8, 1))
    #expect(inclusiveEnd == localDate(2026, 8, 3))
    #expect(exclusiveEnd == localDate(2026, 8, 4))
    #expect(aggregation == .daily)
    #expect(validated.timeZoneIdentifier == "Asia/Seoul")
}

@Test
func validatorRejectsDailyStepRangeOutsideCurrentAndPreviousMonth() {
    let validator = NativeToolProposalValidator(
        now: localDate(2026, 8, 3, 12),
        calendar: seoulCalendar()
    )
    let proposal = NativeToolProposal(
        requestID: "steps-old",
        tool: .getStepCount,
        arguments: .getStepCount(
            StepCountArguments(
                startDate: "2026-06-30",
                endDate: "2026-07-01",
                aggregation: .daily
            )
        )
    )

    do {
        _ = try validator.validate(proposal)
        Issue.record("Expected unsupported range")
    } catch let error as NativeToolValidationError {
        #expect(error.code == .unsupportedRange)
        #expect(error.field == "dateRange")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func validatorRejectsPastSchedules() {
    let validator = NativeToolProposalValidator(
        now: localDate(2026, 8, 3, 12),
        calendar: seoulCalendar()
    )
    let proposal = NativeToolProposal(
        requestID: "alarm-past",
        tool: .createAlarm,
        arguments: .createAlarm(
            CreateAlarmArguments(
                date: "2026-08-03",
                hour: 11,
                minute: 59,
                label: "지난 알람"
            )
        )
    )

    do {
        _ = try validator.validate(proposal)
        Issue.record("Expected past schedule rejection")
    } catch let error as NativeToolValidationError {
        #expect(error.code == .pastSchedule)
        #expect(error.field == "dateTime")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func validatorDefaultsCalendarEventToOneHour() throws {
    let validator = NativeToolProposalValidator(
        now: localDate(2026, 8, 3, 12),
        calendar: seoulCalendar()
    )
    let proposal = NativeToolProposal(
        requestID: "calendar-create",
        tool: .createCalendarEvent,
        arguments: .createCalendarEvent(
            CalendarEventArguments(
                title: "멘토링",
                startDateTime: "2026-08-04T15:00"
            )
        )
    )

    let validated = try validator.validate(proposal)
    guard case .createCalendarEvent(
        let title,
        let start,
        let end,
        let location
    ) = validated.arguments else {
        Issue.record("Expected calendar event arguments")
        return
    }

    #expect(title == "멘토링")
    #expect(start == localDate(2026, 8, 4, 15))
    #expect(end == localDate(2026, 8, 4, 16))
    #expect(location == nil)
}

@Test
func validatorAllows31CalendarDaysButRejects32() throws {
    let validator = NativeToolProposalValidator(
        now: localDate(2026, 8, 3, 12),
        calendar: seoulCalendar()
    )
    let allowed = NativeToolProposal(
        requestID: "calendar-31",
        tool: .getCalendarEvents,
        arguments: .getCalendarEvents(
            CalendarQueryArguments(
                startDate: "2026-08-01",
                endDate: "2026-08-31"
            )
        )
    )
    let rejected = NativeToolProposal(
        requestID: "calendar-32",
        tool: .getCalendarEvents,
        arguments: .getCalendarEvents(
            CalendarQueryArguments(
                startDate: "2026-08-01",
                endDate: "2026-09-01"
            )
        )
    )

    _ = try validator.validate(allowed)
    do {
        _ = try validator.validate(rejected)
        Issue.record("Expected 32-day range rejection")
    } catch let error as NativeToolValidationError {
        #expect(error.code == .unsupportedRange)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func validatorRejectsToolAndArgumentMismatch() {
    let proposal = NativeToolProposal(
        requestID: "mismatch",
        tool: .listAlarms,
        arguments: .createTimer(
            CreateTimerArguments(durationSeconds: 60, label: "차")
        )
    )

    do {
        _ = try NativeToolProposalValidator().validate(proposal)
        Issue.record("Expected tool mismatch rejection")
    } catch let error as NativeToolValidationError {
        #expect(error.code == .invalidArguments)
        #expect(error.field == "tool")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private actor ExecutionCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

@Test
func coordinatorNeverExecutesBeforeConfirmation() async throws {
    let counter = ExecutionCounter()
    let coordinator = NativeToolProposalCoordinator { _ in
        await counter.increment()
        return .object(["ok": .bool(true)])
    }
    let proposal = validatedTimer(requestID: "timer-before-confirm")
    _ = try await coordinator.register(proposal)

    do {
        _ = try await coordinator.approveAndExecute(proposal)
        Issue.record("Expected confirmation transition failure")
    } catch let error as NativeToolCoordinatorError {
        #expect(error == .invalidTransition)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let executionCount = await counter.value()
    #expect(executionCount == 0)
}

@Test
func coordinatorExecutesConfirmedRequestAtMostOnce() async throws {
    let counter = ExecutionCounter()
    let coordinator = NativeToolProposalCoordinator { proposal in
        await counter.increment()
        return .object([
            "requestId": .string(proposal.requestID),
        ])
    }
    let proposal = validatedTimer(requestID: "timer-once")
    let ready = try await coordinator.register(proposal)
    let awaiting = try await coordinator.beginConfirmation(
        requestID: proposal.requestID
    )
    let result = try await coordinator.approveAndExecute(proposal)

    #expect(ready.state == .proposalReady)
    #expect(awaiting.state == .awaitingConfirmation)
    #expect(result.status == .success)
    #expect(result.data == .object(["requestId": .string("timer-once")]))

    do {
        _ = try await coordinator.approveAndExecute(proposal)
        Issue.record("Expected duplicate execution rejection")
    } catch let error as NativeToolCoordinatorError {
        #expect(error == .requestAlreadyExecuted)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    let executionCount = await counter.value()
    let snapshot = await coordinator.snapshot(requestID: proposal.requestID)
    #expect(executionCount == 1)
    #expect(snapshot?.state == .completed)
    #expect(snapshot?.hasExecuted == true)
}

@Test
func coordinatorCancellationNeverCallsAdapter() async throws {
    let counter = ExecutionCounter()
    let coordinator = NativeToolProposalCoordinator { _ in
        await counter.increment()
        return .null
    }
    let proposal = validatedTimer(requestID: "timer-cancel")
    _ = try await coordinator.register(proposal)
    _ = try await coordinator.beginConfirmation(requestID: proposal.requestID)

    let result = try await coordinator.cancel(requestID: proposal.requestID)
    let executionCount = await counter.value()
    let snapshot = await coordinator.snapshot(requestID: proposal.requestID)

    #expect(result.status == .cancelled)
    #expect(result.errorCode == .cancelledByUser)
    #expect(executionCount == 0)
    #expect(snapshot?.state == .cancelled)
}

@Test
func coordinatorMapsNativeErrorsToStableEnvelope() async throws {
    let coordinator = NativeToolProposalCoordinator { _ in
        throw NativeToolErrorCode.permissionDenied
    }
    let proposal = validatedTimer(requestID: "timer-denied")
    _ = try await coordinator.register(proposal)
    _ = try await coordinator.beginConfirmation(requestID: proposal.requestID)

    let result = try await coordinator.approveAndExecute(proposal)
    let snapshot = await coordinator.snapshot(requestID: proposal.requestID)

    #expect(result.status == .failure)
    #expect(result.errorCode == .permissionDenied)
    #expect(snapshot?.state == .failed)
    #expect(snapshot?.unityEvent.errorCode == .permissionDenied)
}
