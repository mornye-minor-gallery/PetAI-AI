import Foundation
import CAndroidPlatformJNI
import EdgeLLM

actor AndroidPlatformBridge {
    static let shared = AndroidPlatformBridge()
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var confirmationID: String?
    private var cancellationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func request(operation: String, fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard operation != "confirm" || confirmationID == nil else { throw NativeToolErrorCode.nativeFailure }
        let id = UUID().uuidString
        var body = fields
        body["id"] = .string(id)
        body["operation"] = .string(operation)
        let data = try JSONEncoder().encode(JSONValue.object(body))
        guard let json = String(data: data, encoding: .utf8) else { throw NativeToolErrorCode.nativeFailure }
        petai_platform_set_reply(androidPlatformReply)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if operation == "confirm" { confirmationID = id }
            let result = json.withCString { petai_platform_submit($0) }
            if result != 1 {
                pending.removeValue(forKey: id)?.resume(throwing: NativeToolErrorCode.nativeFailure)
                if confirmationID == id { confirmationID = nil }
                print("ANDROID_PLATFORM submission_failed code=\(result)")
            }
        }
    }

    func receive(_ json: String) {
        struct Reply: Decodable { let id: String; let data: JSONValue?; let errorCode: String? }
        do {
            let reply = try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
            guard let continuation = pending.removeValue(forKey: reply.id) else { return }
            if confirmationID == reply.id { confirmationID = nil }
            let waiters = cancellationWaiters.removeValue(forKey: reply.id) ?? []
            defer { for waiter in waiters { waiter.resume() } }
            if let code = reply.errorCode {
                if code == "cancelled_by_user" { continuation.resume(throwing: NativeToolConfirmationError.cancelled) }
                else { continuation.resume(throwing: NativeToolErrorCode(rawValue: code) ?? .nativeFailure) }
            } else if let data = reply.data { continuation.resume(returning: data) }
            else { continuation.resume(throwing: NativeToolErrorCode.nativeFailure) }
        } catch { print("ANDROID_PLATFORM reply_decoding_failed") }
    }

    func cancelConfirmation() async {
        guard let id = confirmationID else { return }
        let body: JSONValue = .object(["id": .string(UUID().uuidString),
            "operation": .string("cancel_confirmation"), "targetID": .string(id)])
        do {
            let json = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
            await withCheckedContinuation { waiter in
                cancellationWaiters[id, default: []].append(waiter)
                let result = json.withCString { petai_platform_submit($0) }
                if result != 1 {
                    print("ANDROID_PLATFORM cancellation_submission_failed code=\(result)")
                    for waiting in cancellationWaiters.removeValue(forKey: id) ?? [] { waiting.resume() }
                }
            }
        } catch { print("ANDROID_PLATFORM cancellation_encoding_failed") }
    }
}

private func androidPlatformReply(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let json = String(cString: pointer)
    Task { await AndroidPlatformBridge.shared.receive(json) }
}
