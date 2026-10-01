#if os(Android)
import Foundation
import CLiteRTLM

/// Mirrors the small OSLog surface used by this wrapper. Private interpolations stay redacted.
public struct Logger: Sendable {
    private let category: String
    public init(subsystem: String, category: String) { self.category = category }
    public func info(_ message: Message) {
        category.withCString { tag in
            message.text.withCString { _ = __android_log_write(Int32(ANDROID_LOG_INFO.rawValue), tag, $0) }
        }
    }
    public func notice(_ message: Message) { info(message) }
    public func debug(_ message: Message) { info(message) }
    public func error(_ message: Message) { info(message) }
    public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let text: String
        public init(stringLiteral value: String) { text = value }
        public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
        public struct StringInterpolation: StringInterpolationProtocol {
            var text = ""
            public enum Privacy { case `public`, `private` }
            public enum Format { case fixed(precision: Int) }
            public init(literalCapacity: Int, interpolationCount: Int) {}
            public mutating func appendLiteral(_ literal: String) { text += literal }
            public mutating func appendInterpolation<T>(_ value: T) { text += "<private>" }
            public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) {
                text += privacy == .public ? String(describing: value) : "<private>"
            }
            public mutating func appendInterpolation<T>(_ value: T, format: Format) { text += "<private>" }
        }
    }
}
#endif
