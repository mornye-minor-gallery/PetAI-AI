import Foundation
import CAndroidDispatch

private struct QueueReadyCallback: @unchecked Sendable {
    let call: @convention(c) (Int32) -> Void
}

@_cdecl("petai_android_main_queue_install")
public func androidMainQueueInstall(_ callback: @convention(c) (Int32) -> Void) -> Int32 {
    let status = petai_main_queue_install_event()
    guard status == 1 else { return status }
    let receiver = QueueReadyCallback(call: callback)
    // Observe execution, rather than assuming installation means the queue is draining.
    Task { @MainActor in receiver.call(petai_is_android_main_thread()) }
    return status
}
