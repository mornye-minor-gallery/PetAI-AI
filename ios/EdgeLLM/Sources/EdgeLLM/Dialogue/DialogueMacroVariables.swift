import Foundation

extension DialogueMacroEvaluator {
    static func numeric(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in:.whitespacesAndNewlines)
        if value.isEmpty { return 0 }
        for (prefix,radix) in [("0x",16),("0b",2),("0o",8)] where value.lowercased().hasPrefix(prefix) {
            return UInt64(value.dropFirst(2),radix:radix).map { Double($0) }
        }
        return Double(value)
    }
    func get(_ key: String, global: Bool) -> String {
        let value = (global ? context.globalVariables : context.localVariables)[key] ?? ""
        if !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, let n = Self.numeric(value) { return Self.number(n) }
        return value
    }
    mutating func set(_ key: String, _ value: String?, global: Bool) throws {
        guard !key.isEmpty else { throw WorldInfoTextError.invalidMacro("Empty variable name") }
        if global { context.globalVariables[key] = value } else { context.localVariables[key] = value }
    }
    mutating func add(_ key: String, _ value: String, global: Bool) throws -> String {
        let current = get(key,global:global)
        let result: String
        if var array = try? JSONDecoder().decode([JSONValue].self,from:Data(current.utf8)) {
            array.append(.string(value)); result = String(decoding:try JSONEncoder().encode(array),as:UTF8.self)
        } else if let a = Self.numeric(current), let b = Self.numeric(value) { result = Self.number(a+b) }
        else { result = current + value }
        try set(key,result,global:global)
        return result
    }
    mutating func variableMacro(_ name: String, values: [String]) throws -> String? {
        let global = name.contains("globalvar")
        let suffix = global ? "globalvar" : "var"
        let operations = ["set","get","add","inc","dec","has","delete"]
        guard let operation = operations.first(where: { name == $0+suffix || name == $0+suffix+"key" }) else { return nil }
        guard let key = values.first else { throw WorldInfoTextError.invalidMacro("\(name) requires name") }
        if name.hasSuffix("key") {
            guard values.count >= 2 else { throw WorldInfoTextError.invalidMacro("Missing variable index") }
            let raw = get(key,global:global)
            var value = (try? JSONDecoder().decode(JSONValue.self,from:Data(raw.utf8))) ?? .null
            let index = values[1]
            if operation == "set" {
                guard values.count >= 3 else { throw WorldInfoTextError.invalidMacro("Missing indexed value") }
                if let i = Int(index), (0...100_000).contains(i) {
                    var array: [JSONValue] = []; if case .array(let existing) = value { array = existing }
                    while array.count <= i { array.append(.null) }; array[i] = .string(values[2]); value = .array(array)
                } else {
                    var object: [String:JSONValue] = [:]; if case .object(let existing) = value { object = existing }
                    object[index] = .string(values[2]); value = .object(object)
                }
                try set(key,scalar(value),global:global); return ""
            }
            if case .array(let array) = value, let i = Int(index), array.indices.contains(i) { return scalar(array[i]) }
            if case .object(let object) = value { return object[index].map(scalar) ?? "" }
            return ""
        }
        switch operation {
        case "get": return get(key,global:global)
        case "has": return String((global ? context.globalVariables : context.localVariables)[key] != nil)
        case "delete": try set(key,nil,global:global); return ""
        case "set", "add":
            guard values.count >= 2 else { throw WorldInfoTextError.invalidMacro("\(name) requires value") }
            if operation == "set" { try set(key,values[1],global:global) } else { _ = try add(key,values[1],global:global) }; return ""
        case "inc": return try add(key,"1",global:global)
        default: return try add(key,"-1",global:global)
        }
    }
    mutating func variableShorthand(_ expression: String, offset: Int) throws -> String {
        guard expression.hasPrefix(".") || expression.hasPrefix("$"),
              !expression.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorldInfoTextError.invalidMacro("variable requires a scoped name")
        }
        let global = expression.hasPrefix("$")
        let pattern = try NSRegularExpression(pattern: #"^[.$]([\w-]+?)\s*(\?\?=|\|\|=|\?\?|\|\||\+\+|--|\+=|-=|==|!=|>=|<=|>|<|=)\s*(.*)$"#,options:.dotMatchesLineSeparators)
        let ns = expression as NSString
        guard let match = pattern.firstMatch(in:expression,range:NSRange(location:0,length:ns.length)) else {
            return get(String(expression.dropFirst()).trimmingCharacters(in:.whitespaces),global:global)
        }
        let key = ns.substring(with:match.range(at:1))
        let op = ns.substring(with:match.range(at:2))
        let raw = ns.substring(with:match.range(at:3))
        let current = get(key,global:global)
        let exists = (global ? context.globalVariables : context.localVariables)[key] != nil
        let falsy = ["","0","false","off"].contains(current.lowercased())
        if op == "" { return current }
        if ["??","??="].contains(op), exists { return current }
        if ["||","||="].contains(op), !falsy { return current }
        if op == "++" { return try add(key,"1",global:global) }
        if op == "--" { return try add(key,"-1",global:global) }
        let value = try nested(raw,offset:offset)
        switch op {
        case "=", "??=", "||=": try set(key,value,global:global); return op == "=" ? "" : value
        case "??", "||": return value
        case "+=": _ = try add(key,value,global:global); return ""
        case "-=": guard let n = Self.numeric(value) else { throw WorldInfoTextError.invalidMacro("Non-numeric subtraction") }; _ = try add(key,Self.number(-n),global:global); return ""
        case "==": return String(current == value)
        case "!=": return String(current != value)
        case ">", "<", ">=", "<=":
            guard let a = Self.numeric(current), let b = Self.numeric(value) else { throw WorldInfoTextError.invalidMacro("Non-numeric comparison") }
            return String(op == ">" ? a>b : op == "<" ? a<b : op == ">=" ? a>=b : a<=b)
        default: throw WorldInfoTextError.invalidMacro(expression)
        }
    }
}
