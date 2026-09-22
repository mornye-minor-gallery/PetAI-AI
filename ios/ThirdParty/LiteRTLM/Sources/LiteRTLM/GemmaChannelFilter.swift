import Foundation

/// Gemma 4 text-only output framing. Input formatting remains the native model
/// template's responsibility. Hold partial delimiters across callback boundaries.
struct GemmaChannelFilter {
    private var buffer = ""
    private var inside = false
    private let start = "<|channel>"
    private let end = "<channel|>"

    init(prefill: String = "") {
        if let last = prefill.range(of: "<|channel>", options: .backwards) {
            inside = prefill[last.upperBound...].range(of: "<channel|>") == nil
        }
    }

    mutating func append(_ text: String) -> String {
        buffer += text
        var output = ""
        while !buffer.isEmpty {
            let marker = inside ? end : start
            if let range = buffer.range(of: marker) {
                if !inside { output += buffer[..<range.lowerBound] }
                buffer = String(buffer[range.upperBound...])
                inside.toggle()
            } else {
                var hold = 0
                for count in 1..<marker.count where buffer.hasSuffix(marker.prefix(count)) { hold = count }
                if !inside { output += buffer.dropLast(hold) }
                buffer = String(buffer.suffix(hold))
                break
            }
        }
        return output
    }

    mutating func finish() -> String {
        defer { buffer = "" }
        // A partial control marker is not user-visible prose.
        if inside || (!buffer.isEmpty && start.hasPrefix(buffer) && buffer.count > 1) { return "" }
        return buffer
    }
}
