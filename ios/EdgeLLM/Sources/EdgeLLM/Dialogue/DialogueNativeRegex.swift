import Foundation

/// Native adapter for the authored regex contract. Unsupported dialect semantics fail explicitly.
struct DialogueNativeRegex {
    let regex: NSRegularExpression
    let global: Bool
    let sticky: Bool
    let unicode: Bool
    let insensitive: Bool
    static func key(_ value: String) throws -> Self? {
        guard value.hasPrefix("/"), let slash = value.lastIndex(of: "/"), slash != value.startIndex else { return nil }
        let body = String(value[value.index(after:value.startIndex)..<slash])
        let flags = String(value[value.index(after:slash)...])
        guard !body.isEmpty, flags.allSatisfy({ "gimsuy".contains($0) }), Set(flags).count == flags.count else { return nil }
        var escaped = false
        for char in body {
            if char == "/" && !escaped { return nil }
            escaped = char == "\\" && !escaped
        }
        return try compile(body, flags: flags)
    }
    static func script(_ value: String) throws -> Self? {
        if value.hasPrefix("/") { return try key(value) }
        return try compile(value, flags: "")
    }
    private static func compile(_ source: String, flags: String) throws -> Self? {
        // ICU-only syntax must never acquire meaning merely because the backend accepts it.
        for syntax in ["(?i", "(?x", "(?s", "(?m", "(?>", "(?|", "\\R", "\\X", "\\Q", "\\G", "\\K", "&&", "*+", "++", "?+", "}+"] where source.contains(syntax) {
            throw WorldInfoTextError.invalidRegex("Unsupported regular-expression syntax: \(syntax)")
        }
        if !flags.contains("u"), source.unicodeScalars.contains(where: { $0.value > 0xFFFF }) {
            throw WorldInfoTextError.invalidRegex("Non-BMP patterns require the Unicode flag")
        }
        if (source.contains("(?<=") || source.contains("(?<!")) && (source.contains("+") || source.contains("*") || source.contains("{")) {
            throw WorldInfoTextError.invalidRegex("Variable-length lookbehind is not supported")
        }
        var pattern = "", escaped = false, inClass = false
        for c in source {
            if escaped {
                switch c {
                case "v": pattern += "\\x0B"
                case "d": pattern += "[0-9]"
                case "D": if inClass { throw WorldInfoTextError.invalidRegex("\\D in character class") }; pattern += "[^0-9]"
                case "w": pattern += "[A-Za-z0-9_]"
                case "W": if inClass { throw WorldInfoTextError.invalidRegex("\\W in character class") }; pattern += "[^A-Za-z0-9_]"
                case "s": pattern += "[\\u0009-\\u000D\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]"
                case "S":
                    if inClass { throw WorldInfoTextError.invalidRegex("\\S in character class") }
                    pattern += "[^\\u0009-\\u000D\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]"
                case "b", "B":
                    if inClass { pattern += c == "b" ? "\\x08" : "B" }
                    else if c == "b" { pattern += "(?:(?<![A-Za-z0-9_])(?=[A-Za-z0-9_])|(?<=[A-Za-z0-9_])(?![A-Za-z0-9_]))" }
                    else { pattern += "(?:(?<![A-Za-z0-9_])(?![A-Za-z0-9_])|(?<=[A-Za-z0-9_])(?=[A-Za-z0-9_]))" }
                case "1"..."9", "k", "p", "P": throw WorldInfoTextError.invalidRegex("Backreferences and Unicode properties are not supported")
                default: pattern += "\\" + String(c)
                }
                escaped = false; continue
            }
            if c == "\\" { escaped = true; continue }
            if c == "[" { inClass = true }; if c == "]" { inClass = false }
            if c == "$" && !inClass { pattern += flags.contains("m") ? "(?:\\z|(?=[\\n\\r\\u2028\\u2029]))" : "\\z" }
            else if c == "^" && !inClass { pattern += flags.contains("m") ? "(?:\\A|(?<=[\\n\\r\\u2028\\u2029]))" : "\\A" }
            else if c == "." && !inClass && !flags.contains("s") { pattern += "[^\\n\\r\\u2028\\u2029]" }
            else { pattern.append(c) }
        }
        if escaped { return nil }
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return .init(regex: regex, global: flags.contains("g"), sticky: flags.contains("y"), unicode: flags.contains("u"), insensitive: flags.contains("i"))
    }
    func matches(_ text: String) throws -> [NSTextCheckingResult] {
        if !unicode && text.unicodeScalars.contains(where: { $0.value > 0xFFFF }) {
            throw WorldInfoTextError.invalidRegex("Non-BMP input requires the Unicode regex flag")
        }
        if insensitive && text.unicodeScalars.contains(where: { $0.value > 127 }) {
            throw WorldInfoTextError.invalidRegex("Unicode case-fold equivalence is not verified")
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result: [NSTextCheckingResult] = [], end = 0
        for match in matches {
            if sticky && match.range.location != end { break }
            result.append(match); end = match.range.location + match.range.length
            if global && match.range.length == 0 {
                let ns = text as NSString
                end += unicode && end < ns.length && (0xD800...0xDBFF).contains(ns.character(at:end)) ? 2 : 1
            }
            if !global { break }
        }
        return result
    }
    static func replacing(_ text: String, pattern: String, replacement: String,
                          filterCapture: (String) throws -> String = { $0 }, transform: (String) throws -> String) throws -> String {
        guard let compiled = try script(pattern) else { return text }
        let ns = text as NSString
        var result = "", position = 0
        let capturePattern = try NSRegularExpression(pattern: #"\$(\d+)|\$<([^>]+)>"#)
        for match in try compiled.matches(text) {
            result += ns.substring(with: NSRange(location:position,length:match.range.location-position))
            let template = replacement.replacingOccurrences(of:"{{match}}",with:"$0",options:.caseInsensitive)
            let templateNS = template as NSString
            var substitution = "", last = 0
            for capture in capturePattern.matches(in:template,range:NSRange(location:0,length:templateNS.length)) {
                substitution += templateNS.substring(with:NSRange(location:last,length:capture.range.location-last))
                let range: NSRange
                if capture.range(at:1).location != NSNotFound {
                    let index = Int(templateNS.substring(with:capture.range(at:1))) ?? Int.max
                    range = index < match.numberOfRanges ? match.range(at:index) : NSRange(location:NSNotFound,length:0)
                } else { range = match.range(withName:templateNS.substring(with:capture.range(at:2))) }
                if range.location != NSNotFound {
                    substitution += try filterCapture(ns.substring(with:range))
                }
                last = capture.range.location + capture.range.length
            }
            substitution += templateNS.substring(from:last)
            result += try transform(substitution)
            position = match.range.location + match.range.length
        }
        return result + ns.substring(from:position)
    }
}
