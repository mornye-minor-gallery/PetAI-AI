import Foundation

indirect enum DialogueMacroNode {
    case text(String)
    case call(name: String, arguments: [String], body: [DialogueMacroNode]?, offset: Int)
}

/// Balanced delimiters are parsed before evaluation. Unchosen conditional branches never run.
enum DialogueMacroParser {
    private struct Token { let text: String; let offset: Int; let macro: Bool }
    static func parse(_ text: String, base: Int = 0) throws -> [DialogueMacroNode] {
        let units = Array(text.utf16)
        var tokens: [Token] = [], start = 0, cursor = 0
        func string(_ a: Int, _ b: Int) -> String { String(decoding: units[a..<b], as: UTF16.self) }
        while cursor + 1 < units.count {
            if units[cursor] == 92, cursor + 2 < units.count, units[cursor+1] == 123, units[cursor+2] == 123 {
                if cursor > start { tokens.append(.init(text: string(start,cursor), offset: base+start, macro: false)) }
                tokens.append(.init(text: "{{", offset: base+cursor, macro: false))
                cursor += 3; start = cursor; continue
            }
            guard units[cursor] == 123, units[cursor+1] == 123 else { cursor += 1; continue }
            if cursor > start { tokens.append(.init(text: string(start,cursor), offset: base+start, macro: false)) }
            let opening = cursor
            cursor += 2
            var depth = 1
            while cursor + 1 < units.count && depth > 0 {
                if units[cursor] == 123 && units[cursor+1] == 123 { depth += 1; guard depth <= 128 else { throw WorldInfoTextError.invalidMacro("Macro nesting exceeds 128") }; cursor += 2 }
                else if units[cursor] == 125 && units[cursor+1] == 125 { depth -= 1; cursor += 2 }
                else { cursor += 1 }
            }
            guard depth == 0 else { throw WorldInfoTextError.invalidMacro("Unclosed delimiter at \(base+opening)") }
            tokens.append(.init(text: string(opening+2,cursor-2), offset: base+opening, macro: true))
            start = cursor
        }
        if start < units.count { tokens.append(.init(text: string(start,units.count), offset: base+start, macro: false)) }
        var pairs: [Int:Int] = [:], stack: [(String,Int)] = []
        for (i,token) in tokens.enumerated() where token.macro {
            let (name, _) = split(token.text)
            if name.hasPrefix("/"), name != "//" {
                let target = String(name.dropFirst())
                guard let found = stack.lastIndex(where: { $0.0 == target }) else { throw WorldInfoTextError.invalidMacro("Unmatched closing \(name)") }
                pairs[stack[found].1] = i
                stack.removeSubrange(found...)
            } else { stack.append((name.hasPrefix("#") ? String(name.dropFirst()) : name,i)) }
        }
        func nodes(_ range: Range<Int>, depth: Int = 0) throws -> [DialogueMacroNode] {
            guard depth <= 128 else { throw WorldInfoTextError.invalidMacro("Block nesting exceeds 128") }
            var result: [DialogueMacroNode] = [], i = range.lowerBound
            while i < range.upperBound {
                let token = tokens[i]
                if !token.macro { result.append(.text(token.text)); i += 1; continue }
                let (name,args) = split(token.text)
                if let end = pairs[i] {
                    result.append(.call(name: name, arguments: args, body: try nodes((i+1)..<end, depth: depth+1), offset: token.offset)); i = end+1
                } else {
                    result.append(.call(name: name, arguments: args, body: nil, offset: token.offset)); i += 1
                }
            }
            return result
        }
        return try nodes(0..<tokens.count)
    }
    static func split(_ text: String) -> (String,[String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") || trimmed.hasPrefix("$") { return ("variable",[trimmed]) }
        let chars = Array(trimmed)
        var first = 0
        while first < chars.count && chars[first] != ":" && !chars[first].isWhitespace { first += 1 }
        let name = String(chars.prefix(first)).lowercased()
        var rest = String(chars.dropFirst(first)).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasPrefix("::") { rest.removeFirst(2) } else if rest.hasPrefix(":") { rest.removeFirst() }
        guard !rest.isEmpty else { return (name,[]) }
        var args: [String] = [], part = "", depth = 0, i = rest.startIndex
        while i < rest.endIndex {
            let suffix = rest[i...]
            if suffix.hasPrefix("{{") { depth += 1; part += "{{"; i = rest.index(i,offsetBy:2) }
            else if suffix.hasPrefix("}}") { depth -= 1; part += "}}"; i = rest.index(i,offsetBy:2) }
            else if suffix.hasPrefix("::"), depth == 0 { args.append(part.trimmingCharacters(in: .whitespacesAndNewlines)); part = ""; i = rest.index(i,offsetBy:2) }
            else { part.append(rest[i]); i = rest.index(after:i) }
        }
        args.append(part.trimmingCharacters(in: .whitespacesAndNewlines))
        return (name,args)
    }
}
