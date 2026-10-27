import Foundation
import EdgeLLM

/// Calendar choice is Android host state, not an extra field for the model to invent.
actor AndroidCalendarAdapter {
    private let bridge = AndroidPlatformBridge.shared
    private var choice: (requestID: String, calendarID: Int64)?

    func clearChoice() { choice = nil }

    func confirm(_ draft: NativeToolProposal) async throws -> NativeToolProposal {
        choice = nil
        let fields: [String: JSONValue]
        switch draft.arguments {
        case .getCalendarEvents(let value):
            fields = ["startDate": .string(value.startDate), "endDate": .string(value.endDate)]
        case .createCalendarEvent(let value):
            fields = ["title": .string(value.title), "startDateTime": .string(value.startDateTime),
                "endDateTime": value.endDateTime.map(JSONValue.string) ?? .null,
                "location": value.location.map(JSONValue.string) ?? .null]
        default: throw NativeToolErrorCode.invalidArguments
        }
        let result = try await bridge.request(operation: "confirm", fields: [
            "requestID": .string(draft.requestID), "tool": .string(draft.tool.rawValue), "arguments": .object(fields)])
        let data = try JSONEncoder().encode(result)
        let edited: NativeToolArguments
        switch draft.tool {
        case .getCalendarEvents:
            edited = .getCalendarEvents(try JSONDecoder().decode(CalendarQueryArguments.self, from: data))
        case .createCalendarEvent:
            guard case .object(let fields) = result, case .number(let raw)? = fields["calendarID"],
                  let id = Int64(exactly: raw), id > 0 else { throw NativeToolErrorCode.dataUnavailable }
            edited = .createCalendarEvent(try JSONDecoder().decode(CalendarEventArguments.self, from: data))
            choice = (draft.requestID, id)
        default: throw NativeToolErrorCode.invalidArguments
        }
        return NativeToolProposal(requestID: draft.requestID, tool: draft.tool, arguments: edited)
    }

    func execute(_ proposal: ValidatedToolProposal) async throws -> JSONValue {
        let fields: [String: JSONValue]
        let reading: Bool
        switch proposal.arguments {
        case .getCalendarEvents(let start, _, let end, let limit):
            fields = ["startAtMillis": millis(start), "endAtMillis": millis(end), "limit": .number(Double(limit)),
                "timeZoneIdentifier": .string(proposal.timeZoneIdentifier)]
            reading = true
        case .createCalendarEvent(let title, let start, let end, let location):
            guard let selected = choice, selected.requestID == proposal.requestID else { throw NativeToolErrorCode.dataUnavailable }
            choice = nil
            fields = ["title": .string(title), "startAtMillis": millis(start), "endAtMillis": millis(end),
                "location": location.map(JSONValue.string) ?? .null,
                "calendarID": .number(Double(selected.calendarID)), "timeZoneIdentifier": .string(proposal.timeZoneIdentifier)]
            reading = false
        default: throw NativeToolErrorCode.invalidArguments
        }
        return try await bridge.request(operation: "execute", fields: ["requestID": .string(proposal.requestID),
            "tool": .string(proposal.tool.rawValue), "arguments": .object(fields)],
            cancellableReadRequestID: reading ? proposal.requestID : nil)
    }

    private func millis(_ date: Date) -> JSONValue { .number((date.timeIntervalSince1970 * 1000).rounded()) }
}
