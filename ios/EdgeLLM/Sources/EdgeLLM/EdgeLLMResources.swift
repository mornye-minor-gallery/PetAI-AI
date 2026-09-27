import Foundation

/// Android hosts supply the extracted SwiftPM bundle before loading runtime defaults.
public enum EdgeLLMResources {
    public enum ResourceError: Error { case bundleMissing, bundleAlreadyConfigured }
#if os(Android)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured: Bundle?

    public static func configure(bundleURL: URL) throws {
        guard let bundle = Bundle(url: bundleURL),
              bundle.url(forResource: "slm-runtime-defaults", withExtension: "json") != nil else {
            throw ResourceError.bundleMissing
        }
        lock.lock()
        defer { lock.unlock() }
        if let configured, configured.bundleURL != bundle.bundleURL {
            throw ResourceError.bundleAlreadyConfigured
        }
        configured = bundle
    }
#endif

    static func bundle() throws -> Bundle {
#if os(Android)
        lock.lock()
        defer { lock.unlock() }
        guard let configured else { throw ResourceError.bundleMissing }
        return configured
#elseif SWIFT_PACKAGE
        return .module
#else
        return .main
#endif
    }
}
