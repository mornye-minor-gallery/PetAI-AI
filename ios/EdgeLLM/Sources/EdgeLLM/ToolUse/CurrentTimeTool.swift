import Foundation

struct CurrentTimeTool: Sendable {
    func execute(_ proposal: ValidatedToolProposal, now: Date = Date()) throws -> JSONValue {
        guard proposal.tool == .getCurrentTime, proposal.arguments == .getCurrentTime,
              TimeZone(identifier: proposal.timeZoneIdentifier) != nil else {
            throw NativeToolErrorCode.invalidArguments
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        // Keep the instant machine-readable; the reply uses the device zone captured for this request.
        return .object([
            "currentDateTime": .string(formatter.string(from: now)),
            "timeZoneIdentifier": .string(proposal.timeZoneIdentifier),
        ])
    }
}
