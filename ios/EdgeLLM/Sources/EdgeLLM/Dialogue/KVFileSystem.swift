#if os(Android)
import Android
#else
import Darwin
#endif

enum KVFileSystem {
    static func open(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
#if os(Android)
        Android.open(path, flags, mode)
#else
        Darwin.open(path, flags, mode)
#endif
    }
#if os(Android)
    static let close = Android.close
    static let read = Android.read
    static let write = Android.write
#else
    static let close = Darwin.close
    static let read = Darwin.read
    static let write = Darwin.write
#endif
}
