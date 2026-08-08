import CoreFoundation
import Foundation

public struct NativeToolFunctionCall: Equatable, Sendable {
    public let name: String
    public let argumentsJSON: Data

    public init(name: String, argumentsJSON: Data) {
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    public init(name: String, argumentsJSON: String) {
        self.init(
            name: name,
            argumentsJSON: Data(argumentsJSON.utf8)
        )
    }
}

public enum NativeToolProposalParserError: Error, Equatable, Sendable {
    case toolMismatch(expected: NativeToolKind, actual: String)
    case invalidJSON
    case unexpectedFields
    case missingField(String)
    case invalidFieldType(String)
}

public struct NativeToolProposalParser: Sendable {
    public init() {}

    public func parse(
        _ call: NativeToolFunctionCall,
        selectedTool: NativeToolKind,
        requestID: String
    ) throws -> NativeToolProposal {
        guard call.name == selectedTool.rawValue else {
            throw NativeToolProposalParserError.toolMismatch(
                expected: selectedTool,
                actual: call.name
            )
        }
        guard
            let object = try? JSONSerialization.jsonObject(
                with: call.argumentsJSON
            ),
            let fields = object as? [String: Any]
        else {
            throw NativeToolProposalParserError.invalidJSON
        }

        let arguments: NativeToolArguments
        switch selectedTool {
        case .getStepCount:
            try requireFields(
                fields,
                required: ["startDate", "endDate", "aggregation"]
            )
            let startDate = try requiredString(fields, "startDate")
            let endDate = try requiredString(fields, "endDate")
            let rawAggregation = try requiredString(fields, "aggregation")
            guard let aggregation = StepCountAggregation(
                rawValue: rawAggregation
            ) else {
                throw NativeToolProposalParserError.invalidFieldType(
                    "aggregation"
                )
            }
            arguments = .getStepCount(
                StepCountArguments(
                    startDate: startDate,
                    endDate: endDate,
                    aggregation: aggregation
                )
            )

        case .createAlarm:
            try requireFields(
                fields,
                required: ["date", "hour", "minute", "label"]
            )
            let date = try requiredString(fields, "date")
            let hour = try requiredInteger(fields, "hour")
            let minute = try requiredInteger(fields, "minute")
            let label = try requiredString(fields, "label")
            arguments = .createAlarm(
                CreateAlarmArguments(
                    date: date,
                    hour: hour,
                    minute: minute,
                    label: label
                )
            )

        case .listAlarms:
            try requireFields(fields, required: [])
            arguments = .listAlarms

        case .createTimer:
            try requireFields(
                fields,
                required: ["durationSeconds", "label"]
            )
            let durationSeconds = try requiredInteger(
                fields,
                "durationSeconds"
            )
            let label = try requiredString(fields, "label")
            arguments = .createTimer(
                CreateTimerArguments(
                    durationSeconds: durationSeconds,
                    label: label
                )
            )

        case .scheduleLocalNotification:
            try requireFields(
                fields,
                required: ["dateTime", "title", "body"]
            )
            let dateTime = try requiredString(fields, "dateTime")
            let title = try requiredString(fields, "title")
            let body = try requiredString(fields, "body")
            arguments = .scheduleLocalNotification(
                LocalNotificationArguments(
                    dateTime: dateTime,
                    title: title,
                    body: body
                )
            )

        case .getCalendarEvents:
            try requireFields(
                fields,
                required: ["startDate", "endDate"]
            )
            let startDate = try requiredString(fields, "startDate")
            let endDate = try requiredString(fields, "endDate")
            arguments = .getCalendarEvents(
                CalendarQueryArguments(
                    startDate: startDate,
                    endDate: endDate
                )
            )

        case .createCalendarEvent:
            try requireFields(
                fields,
                required: ["title", "startDateTime"],
                optional: ["endDateTime", "location"]
            )
            let title = try requiredString(fields, "title")
            let startDateTime = try requiredString(
                fields,
                "startDateTime"
            )
            let endDateTime = try optionalString(fields, "endDateTime")
            let location = try optionalString(fields, "location")
            arguments = .createCalendarEvent(
                CalendarEventArguments(
                    title: title,
                    startDateTime: startDateTime,
                    endDateTime: endDateTime,
                    location: location
                )
            )
        }

        return NativeToolProposal(
            requestID: requestID,
            tool: selectedTool,
            arguments: arguments
        )
    }

    private func requireFields(
        _ fields: [String: Any],
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        let actual = Set(fields.keys)
        let allowed = required.union(optional)
        guard actual.isSubset(of: allowed) else {
            throw NativeToolProposalParserError.unexpectedFields
        }
        for field in required where fields[field] == nil {
            throw NativeToolProposalParserError.missingField(field)
        }
    }

    private func requiredString(
        _ fields: [String: Any],
        _ name: String
    ) throws -> String {
        guard let value = fields[name] else {
            throw NativeToolProposalParserError.missingField(name)
        }
        guard let stringValue = value as? String else {
            throw NativeToolProposalParserError.invalidFieldType(name)
        }
        return stringValue
    }

    private func optionalString(
        _ fields: [String: Any],
        _ name: String
    ) throws -> String? {
        guard let value = fields[name] else { return nil }
        if value is NSNull { return nil }
        guard let stringValue = value as? String else {
            throw NativeToolProposalParserError.invalidFieldType(name)
        }
        return stringValue
    }

    private func requiredInteger(
        _ fields: [String: Any],
        _ name: String
    ) throws -> Int {
        guard let value = fields[name] else {
            throw NativeToolProposalParserError.missingField(name)
        }
        guard let number = value as? NSNumber else {
            throw NativeToolProposalParserError.invalidFieldType(name)
        }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw NativeToolProposalParserError.invalidFieldType(name)
        }
        let doubleValue = number.doubleValue
        guard
            doubleValue.isFinite,
            doubleValue.rounded() == doubleValue,
            doubleValue >= Double(Int.min),
            doubleValue <= Double(Int.max)
        else {
            throw NativeToolProposalParserError.invalidFieldType(name)
        }
        return Int(doubleValue)
    }
}
