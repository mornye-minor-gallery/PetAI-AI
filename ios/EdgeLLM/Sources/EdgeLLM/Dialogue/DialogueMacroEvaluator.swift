import Foundation

struct DialogueMacroEvaluator {
    var context: WorldInfoTextContext
    let original: String
    var escapeResults = false
    var depth = 0
    static let trimMarker = "\u{1F}dialogue-trim\u{1F}"

    mutating func render(_ nodes: [DialogueMacroNode]) throws -> String {
        guard depth < 128 else { throw WorldInfoTextError.invalidMacro("Macro nesting exceeds 128") }
        depth += 1; defer { depth -= 1 }
        var result = ""
        for node in nodes {
            switch node {
            case .text(let text): result += text
            case let .call(name, args, body, offset):
                let value = try call(name, args: args, body: body, offset: offset)
                result += escapeResults ? NSRegularExpression.escapedPattern(for: value) : value
            }
            guard result.utf16.count <= 1_048_576 else { throw WorldInfoTextError.invalidMacro("Expanded text exceeds 1 MiB") }
        }
        result = result.replacingOccurrences(of: "(?:\\r?\\n)*" + Self.trimMarker + "(?:\\r?\\n)*", with: "", options: .regularExpression)
        for (marker,value) in [("<USER>",context.user),("<BOT>",context.char),("<CHAR>",context.char),("<GROUP>",host("group") ?? context.char),("<CHARIFNOTGROUP>",host("group") ?? context.char)] {
            result = result.replacingOccurrences(of:marker,with:value,options:.caseInsensitive)
        }
        return result
    }
    mutating func nested(_ text: String, offset: Int) throws -> String {
        let previous = escapeResults; escapeResults = false; defer { escapeResults = previous }
        let ns = original as NSString
        let start = min(offset,ns.length)
        let found = ns.range(of:text,range:NSRange(location:start,length:ns.length-start))
        return try render(DialogueMacroParser.parse(text,base:found.location == NSNotFound ? offset : found.location))
    }
    mutating func call(_ name: String, args: [String], body: [DialogueMacroNode]?, offset: Int) throws -> String {
        let preserveWhitespace = name.hasPrefix("#")
        let name = preserveWhitespace ? String(name.dropFirst()) : name
        var args = args
        let arity: Int
        if ["random","pick"].contains(name) { arity = Int.max }
        else if name == "setvarkey" || name == "setglobalvarkey" { arity = 3 }
        else if ["if","setvar","setglobalvar","addvar","addglobalvar","getvarkey","getglobalvarkey","timediff"].contains(name) { arity = 2 }
        else { arity = 1 }
        if args.count > arity { args = Array(args.prefix(arity-1)) + [args.dropFirst(arity-1).joined(separator:"::")] }
        if name == "//" || name == "comment" { return "" }
        if name == "if" {
            guard let raw = args.first else { throw WorldInfoTextError.invalidMacro("if requires a condition") }
            let inverted = raw.hasPrefix("!")
            let condition = inverted ? String(raw.dropFirst()).trimmingCharacters(in:.whitespaces) : raw
            var value = try nested(condition,offset:offset)
            if condition.hasPrefix(".") || condition.hasPrefix("$") { value = try variableShorthand(condition,offset:offset) }
            else if let field = simpleField(value) { value = field }
            else if ["noop", "trim", "space", "newline", "time", "date", "weekday", "isotime", "isodate", "greeting", "charfirstmessage"].contains(value.lowercased()) {
                value = try call(value.lowercased(), args: [], body: nil, offset: offset)
            }
            let truth = !["", "false", "off", "0"].contains(value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()) != inverted
            let branch = try body ?? args.dropFirst().first.map { try DialogueMacroParser.parse($0,base:offset) } ?? []
            let split = branch.firstIndex { if case .call(name:"else",arguments:_,body:_,offset:_) = $0 { return true }; return false }
            let chosen: [DialogueMacroNode]
            if truth { chosen = Array(branch.prefix(split ?? branch.count)) }
            else { chosen = split.map { Array(branch.dropFirst($0+1)) } ?? [] }
            let rendered = try render(chosen)
            return preserveWhitespace ? rendered : rendered.trimmingCharacters(in:.whitespacesAndNewlines)
        }
        if name == "variable" {
            // Both shorthand syntax and literal variable calls reach this branch.
            // Malformed authored text must throw before array access or state commit.
            guard let expression = args.first else {
                throw WorldInfoTextError.invalidMacro("variable requires an expression")
            }
            return try variableShorthand(expression, offset: offset)
        }
        var values: [String] = []
        for arg in args { values.append(try nested(arg,offset:offset)) }
        if let body { let rendered = try render(body); values.append(preserveWhitespace ? rendered : rendered.trimmingCharacters(in:.whitespacesAndNewlines)) }
        if let variable = try variableMacro(name,values:values) { return variable }
        if let field = simpleField(name) { return field }
        switch name {
        case "noop", "else": return ""
        case "trim": return body == nil ? Self.trimMarker : values.last ?? ""
        case "space", "newline":
            guard let count = Int(values.first ?? "1"), (0...1_048_576).contains(count) else { throw WorldInfoTextError.invalidMacro("Invalid repeat count") }
            return String(repeating:name == "space" ? " " : "\n",count:count)
        case "reverse": return String(String.UnicodeScalarView((values.first ?? "").unicodeScalars.reversed()))
        case "outlet": return context.outlets[values.first ?? ""] ?? ""
        case "random", "pick":
            var choices = values
            if choices.count == 1 { choices = choices[0].replacingOccurrences(of:"\\,",with:"\u{1E}").components(separatedBy:",").map { $0.trimmingCharacters(in:.whitespaces).replacingOccurrences(of:"\u{1E}",with:",") } }
            guard !choices.isEmpty else { return "" }
            let draw = try name == "random" ? roll() : DialogueMacroRandom.pick(chatID:host("chatID") ?? "", original:original, offset:offset, reroll:host("pickRerollSeed"))
            return choices[min(choices.count-1,Int(draw * Double(choices.count)))]
        case "roll": return try dice(values.first ?? "1d6")
        case "greeting", "charfirstmessage":
            let index = Int(values.first ?? "0") ?? 0
            if index == 0 { return character("firstMessage") }
            guard index > 0 else { return "" }
            guard case .object(let card) = context.runtime?["character"], case .array(let greetings) = card["alternateGreetings"], greetings.indices.contains(index-1) else { return "" }
            return scalar(greetings[index-1])
        case "hasextension":
            guard case .array(let extensions) = context.runtime?["extensions"] else { return "false" }
            return String(extensions.contains(.string(values.first ?? "")))
        case "banned":
            context.bannedWords = (context.bannedWords ?? []) + values.prefix(1); return ""
        case "time", "date", "weekday", "isotime", "isodate", "datetimeformat", "timediff", "idleduration", "idle_duration":
            return try timeMacro(name,values:values)
        default:
            if let instruct = instructField(name) { return instruct }
            if case .object(let dynamic) = context.runtime?["dynamicMacros"], let value = dynamic[name] { return scalar(value) }
            throw WorldInfoTextError.unsupportedMacro(name)
        }
    }
    mutating func roll() throws -> Double {
        guard context.randomIndex >= 0 else { throw WorldInfoTextError.invalidRandomRoll }
        guard context.randomIndex < context.randomRolls.count else { throw WorldInfoTextError.randomSourceExhausted }
        let value = context.randomRolls[context.randomIndex]
        guard value.isFinite, value >= 0, value < 1 else { throw WorldInfoTextError.invalidRandomRoll }
        context.randomIndex += 1
        return value
    }
    func host(_ key: String) -> String? { context.runtime?[key].map(scalar) }
    func scalar(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return Self.number(n)
        case .bool(let b): return String(b)
        case .null: return ""
        default: return String(decoding:(try? JSONEncoder().encode(value)) ?? Data(),as:UTF8.self)
        }
    }
    static func number(_ n: Double) -> String { n.isFinite && n.rounded() == n && abs(n) < 1e18 ? String(format:"%.0f",n) : String(n) }
    func character(_ key: String) -> String {
        guard case .object(let card) = context.runtime?["character"], let value = card[key] else { return "" }
        return scalar(value)
    }
}
