import Foundation
import EdgeLLM

public struct AndroidPlatformTools: ChatPlatformTools {
    public let supportedTools: Set<NativeToolKind> = [.createAlarm, .listAlarms, .createTimer]
    public let unsupportedMessage = "Android에서는 준비 중인 기능입니다."
    private let bridge = AndroidPlatformBridge.shared
    public init() {}

    public func confirm(_ draft: NativeToolProposal) async throws -> NativeToolProposal {
        let arguments: [String: JSONValue]
        switch draft.arguments {
        case .createAlarm(let value):
            arguments = ["date": .string(value.date), "hour": .number(Double(value.hour)),
                "minute": .number(Double(value.minute)), "label": .string(value.label)]
        case .createTimer(let value):
            arguments = ["durationSeconds": .number(Double(value.durationSeconds)), "label": .string(value.label)]
        case .listAlarms: arguments = [:]
        default: throw NativeToolConfirmationError.unsupportedTool(draft.tool)
        }
        do {
            let result = try await bridge.request(operation: "confirm", fields: [
                "requestID": .string(draft.requestID), "tool": .string(draft.tool.rawValue), "arguments": .object(arguments)])
            let data = try JSONEncoder().encode(result)
            let edited: NativeToolArguments
            switch draft.tool {
            case .createAlarm: edited = .createAlarm(try JSONDecoder().decode(CreateAlarmArguments.self, from: data))
            case .createTimer: edited = .createTimer(try JSONDecoder().decode(CreateTimerArguments.self, from: data))
            case .listAlarms: edited = .listAlarms
            default: throw NativeToolErrorCode.invalidArguments
            }
            return NativeToolProposal(requestID: draft.requestID, tool: draft.tool, arguments: edited)
        } catch let code as NativeToolErrorCode {
            throw NativeToolValidationError(code: code, field: "androidPermission")
        }
    }
    public func cancelConfirmation() async { await bridge.cancelConfirmation() }
    public func execute(_ proposal: ValidatedToolProposal) async throws -> JSONValue {
        let arguments: [String: JSONValue]
        switch proposal.arguments {
        case .createAlarm(let date, let label):
            arguments = ["scheduledAtMillis": .number((date.timeIntervalSince1970 * 1000).rounded()), "label": .string(label)]
        case .createTimer(let duration, let label):
            arguments = ["durationSeconds": .number(Double(duration)), "label": .string(label)]
        case .listAlarms: arguments = [:]
        default: throw NativeToolErrorCode.invalidArguments
        }
        return try await bridge.request(operation: "execute", fields: [
            "requestID": .string(proposal.requestID), "tool": .string(proposal.tool.rawValue), "arguments": .object(arguments)])
    }
    public func enrich(_ base: UserProfileContext, allowedTools: Set<NativeToolKind>) async -> UserProfileContext {
        guard !allowedTools.isDisjoint(with: supportedTools) else { return base }
        do {
            struct Snapshot: Decodable {
                struct Alarm: Decodable { let kind: String; let label: String; let scheduledAt: String; let state: String }
                let authorized: Bool
                let alarms: [Alarm]
            }
            let result = try await bridge.request(operation: "snapshot")
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(result))
            guard snapshot.authorized else { return base }
            return UserProfileContext(userName: base.userName, characterName: base.characterName,
                roomPlacementCount: base.roomPlacementCount, unlockedFeatures: base.unlockedFeatures,
                dailySteps: base.dailySteps, alarms: snapshot.alarms.prefix(UserProfileContext.maximumScheduledItemCount).map {
                    .init(kind: $0.kind, label: $0.label, scheduledAt: $0.scheduledAt, state: $0.state)
                }, reminders: base.reminders, alarmCount: snapshot.alarms.count, reminderCount: base.reminderCount)
        } catch {
            // Context enrichment cannot claim a zero count when the OS snapshot failed.
            print("ANDROID_PLATFORM alarm_context_unavailable")
            return base
        }
    }
}
