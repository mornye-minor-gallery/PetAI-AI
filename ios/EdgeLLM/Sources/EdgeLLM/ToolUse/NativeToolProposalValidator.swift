import Foundation

public struct NativeToolValidationError: Error, Equatable, Sendable {
    public let code: NativeToolErrorCode
    public let field: String

    public init(code: NativeToolErrorCode, field: String) {
        self.code = code
        self.field = field
    }
}

public struct NativeToolProposalValidator: Sendable {
    private let now: Date
    private let calendar: Calendar

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    public func validate(
        _ proposal: NativeToolProposal
    ) throws -> ValidatedToolProposal {
        guard !proposal.requestID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw invalid("requestId")
        }
        guard proposal.tool == proposal.arguments.tool else {
            throw invalid("tool")
        }

        let arguments: ValidatedToolArguments
        switch proposal.arguments {
        case .getStepCount(let value):
            let start = try date(value.startDate, field: "startDate")
            let end = try date(value.endDate, field: "endDate")
            try requireOrdered(start, end, field: "dateRange")
            if value.aggregation == .daily {
                try requireDailyStepRange(start: start, end: end)
            }
            arguments = .getStepCount(
                startDate: start,
                inclusiveEndDate: end,
                exclusiveEndDate: try nextDay(after: end),
                aggregation: value.aggregation
            )

        case .createAlarm(let value):
            guard (0...23).contains(value.hour) else {
                throw invalid("hour")
            }
            guard (0...59).contains(value.minute) else {
                throw invalid("minute")
            }
            let day = try date(value.date, field: "date")
            guard let scheduled = calendar.date(
                bySettingHour: value.hour,
                minute: value.minute,
                second: 0,
                of: day
            ) else {
                throw invalid("dateTime")
            }
            try requireFuture(scheduled, field: "dateTime")
            arguments = .createAlarm(
                date: scheduled,
                label: try text(value.label, field: "label", maximum: 80)
            )

        case .listAlarms:
            arguments = .listAlarms

        case .createTimer(let value):
            guard (1...86_400).contains(value.durationSeconds) else {
                throw NativeToolValidationError(
                    code: .unsupportedRange,
                    field: "durationSeconds"
                )
            }
            arguments = .createTimer(
                durationSeconds: value.durationSeconds,
                label: try text(value.label, field: "label", maximum: 80)
            )

        case .scheduleLocalNotification(let value):
            let scheduled = try dateTime(
                value.dateTime,
                field: "dateTime"
            )
            try requireFuture(scheduled, field: "dateTime")
            arguments = .scheduleLocalNotification(
                date: scheduled,
                title: try text(value.title, field: "title", maximum: 120),
                body: try text(value.body, field: "body", maximum: 500)
            )

        case .getCalendarEvents(let value):
            let start = try date(value.startDate, field: "startDate")
            let end = try date(value.endDate, field: "endDate")
            try requireOrdered(start, end, field: "dateRange")
            let dayDistance = calendar.dateComponents(
                [.day],
                from: start,
                to: end
            ).day ?? Int.max
            guard dayDistance <= 30 else {
                throw NativeToolValidationError(
                    code: .unsupportedRange,
                    field: "dateRange"
                )
            }
            arguments = .getCalendarEvents(
                startDate: start,
                inclusiveEndDate: end,
                exclusiveEndDate: try nextDay(after: end),
                limit: 10
            )

        case .createCalendarEvent(let value):
            let start = try dateTime(
                value.startDateTime,
                field: "startDateTime"
            )
            let end: Date
            if let proposedEnd = value.endDateTime {
                end = try dateTime(proposedEnd, field: "endDateTime")
            } else {
                guard let defaultEnd = calendar.date(
                    byAdding: .hour,
                    value: 1,
                    to: start
                ) else {
                    throw invalid("endDateTime")
                }
                end = defaultEnd
            }
            guard end > start else { throw invalid("endDateTime") }
            let normalizedLocation = value.location?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if let normalizedLocation, normalizedLocation.count > 200 {
                throw invalid("location")
            }
            arguments = .createCalendarEvent(
                title: try text(value.title, field: "title", maximum: 120),
                startDate: start,
                endDate: end,
                location: normalizedLocation?.isEmpty == false
                    ? normalizedLocation
                    : nil
            )
        }

        return ValidatedToolProposal(
            requestID: proposal.requestID,
            tool: proposal.tool,
            timeZoneIdentifier: calendar.timeZone.identifier,
            arguments: arguments
        )
    }

    private func date(_ raw: String, field: String) throws -> Date {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard
            parts.count == 3,
            parts[0].count == 4,
            parts[1].count == 2,
            parts[2].count == 2,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else {
            throw invalid(field)
        }
        return try calendarDate(
            DateComponents(year: year, month: month, day: day),
            field: field,
            comparedComponents: [.year, .month, .day]
        )
    }

    private func dateTime(_ raw: String, field: String) throws -> Date {
        let pieces = raw.split(separator: "T", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { throw invalid(field) }
        let dayParts = pieces[0].split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        let timeParts = pieces[1].split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard
            dayParts.count == 3,
            timeParts.count == 2,
            dayParts[0].count == 4,
            dayParts[1].count == 2,
            dayParts[2].count == 2,
            timeParts[0].count == 2,
            timeParts[1].count == 2,
            let year = Int(dayParts[0]),
            let month = Int(dayParts[1]),
            let day = Int(dayParts[2]),
            let hour = Int(timeParts[0]),
            let minute = Int(timeParts[1]),
            (0...23).contains(hour),
            (0...59).contains(minute)
        else {
            throw invalid(field)
        }
        return try calendarDate(
            DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            ),
            field: field,
            comparedComponents: [.year, .month, .day, .hour, .minute]
        )
    }

    private func calendarDate(
        _ components: DateComponents,
        field: String,
        comparedComponents: Set<Calendar.Component>
    ) throws -> Date {
        guard let value = calendar.date(from: components) else {
            throw invalid(field)
        }
        let roundTrip = calendar.dateComponents(comparedComponents, from: value)
        for component in comparedComponents {
            guard roundTrip.value(for: component) == components.value(for: component)
            else {
                throw invalid(field)
            }
        }
        return value
    }

    private func requireOrdered(
        _ start: Date,
        _ end: Date,
        field: String
    ) throws {
        guard start <= end else { throw invalid(field) }
    }

    private func requireFuture(_ value: Date, field: String) throws {
        guard value > now else {
            throw NativeToolValidationError(
                code: .pastSchedule,
                field: field
            )
        }
    }

    private func requireDailyStepRange(start: Date, end: Date) throws {
        let currentMonth = calendar.dateInterval(of: .month, for: now)
        guard
            let currentMonth,
            let previousMonthStart = calendar.date(
                byAdding: .month,
                value: -1,
                to: currentMonth.start
            ),
            let nextMonthStart = calendar.date(
                byAdding: .month,
                value: 1,
                to: currentMonth.start
            ),
            start >= previousMonthStart,
            end < nextMonthStart
        else {
            throw NativeToolValidationError(
                code: .unsupportedRange,
                field: "dateRange"
            )
        }
    }

    private func nextDay(after value: Date) throws -> Date {
        guard let result = calendar.date(byAdding: .day, value: 1, to: value)
        else {
            throw invalid("endDate")
        }
        return result
    }

    private func text(
        _ raw: String,
        field: String,
        maximum: Int
    ) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maximum else {
            throw invalid(field)
        }
        return value
    }

    private func invalid(_ field: String) -> NativeToolValidationError {
        NativeToolValidationError(code: .invalidArguments, field: field)
    }
}
