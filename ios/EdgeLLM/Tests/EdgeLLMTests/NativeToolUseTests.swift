import Foundation
import Testing
@testable import EdgeLLM

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
func localNotificationClarifierRequiresTimeAndContent() {
    let clarifier = LocalNotificationRequestClarifier()

    #expect(
        clarifier.clarification(for: "약 먹으라고 알려 줘")
            == LocalNotificationRequestClarifier.missingTimeMessage
    )
    #expect(
        clarifier.clarification(for: "오후 3시에 알림 설정해 줘")
            == LocalNotificationRequestClarifier.missingContentMessage
    )
    #expect(
        clarifier.clarification(for: "알림 설정해 줘")
            == LocalNotificationRequestClarifier
                .missingTimeAndContentMessage
    )
    #expect(
        clarifier.clarification(
            for: "오후 3시에 약 먹으라고 알려 줘"
        ) == nil
    )
    #expect(
        clarifier.clarification(
            for: "오후 세 시에 약 먹으라고 알려 줘"
        ) == nil
    )
    #expect(
        clarifier.clarification(
            for: "10분 뒤에 스트레칭하라고 알려 줘"
        ) == nil
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

    let validated = try validator.validate(allowed)
    guard case .getCalendarEvents(_, _, _, let limit) = validated.arguments
    else {
        Issue.record("Expected calendar query arguments")
        return
    }
    #expect(limit == 10)
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
