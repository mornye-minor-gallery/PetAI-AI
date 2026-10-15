import Foundation
import EdgeLLM
import AndroidPlatformTools
import CAndroidDispatch
import CAndroidPlatformProbe

@_cdecl("petai_alarm_probe_submit")
public func alarmProbeSubmit(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let json = String(cString: pointer)
    let queue = petai_main_queue_install_event()
    Task {
        var id = "invalid"
        do {
            struct Request: Decodable {
                let id: String; let operation: String; let requestID: String?
                let tool: NativeToolKind?; let arguments: JSONValue?
            }
            let request = try JSONDecoder().decode(Request.self, from: Data(json.utf8)); id = request.id
            guard queue == 1 else { throw NativeToolErrorCode.nativeFailure }
            let tools = AndroidPlatformTools()
            let result: JSONValue
            if request.operation == "cancel_confirmation" {
                await tools.cancelConfirmation(); result = .bool(true)
            } else if request.operation == "enrich" {
                let context = await tools.enrich(UserProfileContext(characterName: "시험 캐릭터"), allowedTools: tools.supportedTools)
                result = .object(["alarmCount": context.alarmCount.map { .number(Double($0)) } ?? .null,
                    "shown": .number(Double(context.alarms.count))])
            } else {
                guard let tool = request.tool else { throw NativeToolErrorCode.invalidArguments }
                let arguments: NativeToolArguments
                let data = try JSONEncoder().encode(request.arguments ?? .object([:]))
                switch tool {
                case .createAlarm: arguments = .createAlarm(try JSONDecoder().decode(CreateAlarmArguments.self, from: data))
                case .createTimer: arguments = .createTimer(try JSONDecoder().decode(CreateTimerArguments.self, from: data))
                case .listAlarms: arguments = .listAlarms
                default: throw NativeToolErrorCode.invalidArguments
                }
                var draft = NativeToolProposal(requestID: request.requestID ?? request.id, tool: tool, arguments: arguments)
                if request.operation == "workflow" { draft = try await tools.confirm(draft) }
                else if request.operation != "execute" { throw NativeToolErrorCode.invalidArguments }
                result = try await tools.execute(NativeToolProposalValidator().validate(draft))
            }
            emit(.object(["id": .string(id), "data": result]))
        } catch let error as NativeToolErrorCode { emit(.object(["id": .string(id), "errorCode": .string(error.rawValue)])) }
        catch let error as NativeToolValidationError { emit(.object(["id": .string(id), "errorCode": .string(error.code.rawValue)])) }
        catch NativeToolConfirmationError.cancelled { emit(.object(["id": .string(id), "errorCode": .string("cancelled_by_user")])) }
        catch { emit(.object(["id": .string(id), "errorCode": .string("native_failure")])) }
    }
}

private func emit(_ value: JSONValue) {
    do {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        text.withCString { petai_alarm_probe_reply($0) }
    } catch { print("ALARM_PROBE result_encoding_failed") }
}
