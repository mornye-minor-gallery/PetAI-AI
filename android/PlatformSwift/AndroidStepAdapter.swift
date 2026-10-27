import Foundation
import EdgeLLM

struct AndroidStepAdapter {
    private let bridge = AndroidPlatformBridge.shared
    func confirm(_ draft: NativeToolProposal) async throws -> NativeToolProposal {
        guard case .getStepCount(let value) = draft.arguments else { throw NativeToolErrorCode.invalidArguments }
        let result = try await bridge.request(operation: "confirm", fields: [
            "requestID": .string(draft.requestID), "tool": .string(draft.tool.rawValue),
            "arguments": .object(["startDate": .string(value.startDate), "endDate": .string(value.endDate),
                "aggregation": .string(value.aggregation.rawValue)])])
        let edited = try JSONDecoder().decode(StepCountArguments.self, from: JSONEncoder().encode(result))
        return NativeToolProposal(requestID: draft.requestID, tool: draft.tool, arguments: .getStepCount(edited))
    }
    func execute(_ proposal: ValidatedToolProposal) async throws -> JSONValue {
        guard case .getStepCount(let start, let end, _, let aggregation) = proposal.arguments,
              let zone = TimeZone(identifier: proposal.timeZoneIdentifier) else { throw NativeToolErrorCode.invalidArguments }
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian); format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone; format.dateFormat = "yyyy-MM-dd"
        return try await bridge.request(operation: "execute", fields: [
            "requestID": .string(proposal.requestID), "tool": .string(proposal.tool.rawValue),
            "arguments": .object(["startDate": .string(format.string(from: start)),
                "endDate": .string(format.string(from: end)), "aggregation": .string(aggregation.rawValue),
                "timeZoneIdentifier": .string(proposal.timeZoneIdentifier)])], cancellableReadRequestID: proposal.requestID)
    }
}
