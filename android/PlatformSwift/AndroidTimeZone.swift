import Foundation
import CAndroidPlatformJNI

enum AndroidTimeZone {
    private static let lock = NSLock()

    static func apply(_ identifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let zone = TimeZone(identifier: identifier) else { return false }
        if TimeZone.current == zone && Calendar.current.timeZone == zone { return true }
        // Foundation's Android system-zone discovery does not read Java's default
        // zone on this SDK. Set its documented TZ input AND invalidate its cache:
        // setting NSTimeZone.default alone leaves TimeZone.current at UTC.
        guard zone.identifier.withCString({ petai_platform_set_time_zone_environment($0) }) == 0 else { return false }
        NSTimeZone.resetSystemTimeZone()
        NSTimeZone.default = zone
        return TimeZone.current == zone && Calendar.current.timeZone == zone
    }
}

@_cdecl("petai_android_apply_time_zone")
public func androidApplyTimeZone(_ pointer: UnsafePointer<CChar>?) -> Int32 {
    guard let pointer, let identifier = String(validatingCString: pointer) else { return 0 }
    return AndroidTimeZone.apply(identifier) ? 1 : 0
}
