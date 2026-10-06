import Foundation
import EdgeLLM
import PetAIChatRuntime
import LiteRTLM

public typealias AndroidChatCallback = @convention(c) (UnsafePointer<CChar>?) -> Void

final class AndroidChatHost: @unchecked Sendable {
    static let shared = AndroidChatHost()
    private let lock = NSLock()
    private var callback: AndroidChatCallback?
    private var controller: ChatSessionController?
    private var configuration: String?

    func setCallback(_ value: AndroidChatCallback?) {
        lock.lock(); defer { lock.unlock() }
        callback = value
    }
    func emitJSON(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        let receiver = callback
        lock.unlock()
        text.withCString { receiver?($0) }
    }
    func emit(_ event: NativeChatEvent) {
        do { emitJSON(try JSONEncoder().encode(event)) }
        catch { print("ANDROID_CHAT event_encoding_failed: \(error)") }
    }
    func emitError(_ message: String) {
        if let data = try? JSONSerialization.data(withJSONObject: [
            "type": "error", "code": "android_host", "message": message]) { emitJSON(data) }
    }
    func configure(_ json: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let configuration {
            guard configuration == json else { throw AndroidHostError.alreadyConfigured }
            return
        }
        let paths = try JSONDecoder().decode(AndroidChatPaths.self, from: Data(json.utf8))
        try EdgeLLMResources.configure(bundleURL: URL(fileURLWithPath: paths.assetsDirectory)
            .appendingPathComponent("EdgeLLM_EdgeLLM.bundle"))
        controller = ChatRuntimeAssembly.makeController(configuration: .production,
            platform: AndroidChatPlatform(paths: paths),
            cacheDirectory: URL(fileURLWithPath: paths.cacheDirectory),
            supportDirectory: URL(fileURLWithPath: paths.supportDirectory),
            eventSink: { [weak self] in self?.emit($0) },
            log: { Logger(subsystem: "PetAI", category: "AndroidChat").notice("\($0, privacy: .public)") })
        configuration = json
    }
    func use(_ operation: @escaping @Sendable (ChatSessionController) async -> Void) {
        lock.lock()
        let value = controller
        lock.unlock()
        guard let value else { emitError(AndroidHostError.notConfigured.localizedDescription); return }
        Task { await operation(value) }
    }
}

@_cdecl("petai_android_configure")
public func petai_android_configure(_ json: UnsafePointer<CChar>?, _ error: UnsafeMutablePointer<CChar>?,
                                     _ capacity: Int32) -> Int32 {
    do {
        guard let json else { throw UnityBridgeError.invalidRequest }
        try AndroidChatHost.shared.configure(String(cString: json))
        return 0
    } catch let failure {
        if let error, capacity > 0 {
            let bytes = Array(failure.localizedDescription.utf8.prefix(Int(capacity) - 1))
            for (i, byte) in bytes.enumerated() { error[i] = CChar(bitPattern: byte) }
            error[bytes.count] = 0
        }
        return -1
    }
}

@_cdecl("petai_set_event_callback")
public func android_set_event_callback(_ callback: AndroidChatCallback?) { AndroidChatHost.shared.setCallback(callback) }
@_cdecl("petai_initialize")
public func android_initialize(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let id = String(cString: pointer)
    AndroidChatHost.shared.use { controller in
        await NativePreparationContext.$requestID.withValue(id) { await controller.initialize() }
    }
}
@_cdecl("petai_select_model")
public func android_select_model(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let id = String(cString: pointer)
    AndroidChatHost.shared.use { controller in
        await NativePreparationContext.$requestID.withValue(id) { await controller.selectModel() }
    }
}
@_cdecl("petai_send")
public func android_send(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let json = String(cString: pointer)
    AndroidChatHost.shared.use { await $0.send(json: json) }
}
@_cdecl("petai_record_home_line")
public func android_home_line(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let json = String(cString: pointer)
    AndroidChatHost.shared.use { await $0.recordHomeLine(json: json) }
}
@_cdecl("petai_cancel")
public func android_cancel(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let requestID = String(cString: pointer)
    AndroidChatHost.shared.use { await $0.cancel(requestID: requestID) }
}
@_cdecl("petai_finalize_turn")
public func android_finalize_turn(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let json = String(cString: pointer)
    AndroidChatHost.shared.use { await $0.finalizeTurn(json: json) }
}
@_cdecl("petai_unload")
public func android_unload() { AndroidChatHost.shared.use { await $0.unload() } }
@_cdecl("petai_request_memory")
public func android_memory(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let id = String(cString: pointer)
    AndroidChatHost.shared.use { await $0.requestMemory(requestId: id) }
}
@_cdecl("petai_cancel_memory")
public func android_cancel_memory() { AndroidChatHost.shared.use { await $0.cancelMemory() } }
@_cdecl("petai_diary_list")
public func android_diary_list(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let id = String(cString: pointer)
    AndroidChatHost.shared.use { await $0.listDiaries(requestId: id) }
}
@_cdecl("petai_diary_create")
public func android_diary_create(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let request = String(cString: pointer)
    AndroidChatHost.shared.use { await $0.requestDiary(json: request) }
}
@_cdecl("petai_data_delete")
public func android_delete(_ pointer: UnsafePointer<CChar>?, _ reset: Bool, _ removeModels: Bool) {
    guard let pointer else { return }
    let id = String(cString: pointer)
    AndroidChatHost.shared.use { await $0.beginDataDeletion(id: id, reset: reset, removeModels: removeModels) }
}
@_cdecl("petai_data_delete_finish")
public func android_delete_finish(_ pointer: UnsafePointer<CChar>?) {
    guard let pointer else { return }
    let id = String(cString: pointer)
    AndroidChatHost.shared.use { await $0.finishDataDeletion(id: id) }
}
