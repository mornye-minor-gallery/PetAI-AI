import Foundation

/// Authored-text state and explicit host inputs, shared by lore and standalone notes.
public struct WorldInfoTextContext: Codable, Equatable, Sendable {
    public var runtime: [String: JSONValue]?
    public var regex: DialogueRegexSettings?
    public var bannedWords: [String]?
    public var user: String
    public var char: String
    public var description: String
    public var personality: String
    public var scenario: String
    public var persona: String
    public var localVariables: [String: String]
    public var globalVariables: [String: String]
    public var outlets: [String: String]
    public var randomRolls: [Double]
    public var randomIndex: Int
    public var picks: [String: String]

    public init(user: String = "", char: String = "", description: String = "", personality: String = "",
                scenario: String = "", persona: String = "", localVariables: [String: String] = [:],
                globalVariables: [String: String] = [:], outlets: [String: String] = [:],
                randomRolls: [Double] = [], randomIndex: Int = 0, picks: [String: String] = [:]) {
        self.user = user; self.char = char; self.description = description
        self.personality = personality; self.scenario = scenario; self.persona = persona
        self.localVariables = localVariables; self.globalVariables = globalVariables; self.outlets = outlets
        self.randomRolls = randomRolls; self.randomIndex = randomIndex; self.picks = picks
    }
}

public enum WorldInfoTextError: Error, Equatable, Sendable {
    case unsupportedMacro(String)
    case invalidMacro(String)
    case randomSourceExhausted
    case invalidRandomRoll
    case invalidRegex(String)
    case missingHostValue(String)
}

/// Pure native entry points shared by authored notes, lore and the evaluation worker.
public enum WorldInfoText {
    public static func expand(_ text: String, context: inout WorldInfoTextContext) throws -> String {
        var evaluator = DialogueMacroEvaluator(context: context, original: text)
        let result = try evaluator.render(DialogueMacroParser.parse(text))
        context = evaluator.context
        return result
    }
    public static func matchesRegex(_ key: String, text: String) throws -> Bool? {
        guard let regex = try DialogueNativeRegex.key(key) else { return nil }
        return try regex.matches(text).first != nil
    }
    public static func replace(_ text: String, pattern: String, replacement: String) throws -> String {
        try DialogueNativeRegex.replacing(text, pattern: pattern, replacement: replacement) { $0 }
    }
    public static func replace(_ text: String, pattern: String, replacement: String,
                               context: inout WorldInfoTextContext) throws -> String {
        var next = context
        let result = try DialogueNativeRegex.replacing(text, pattern: pattern, replacement: replacement) {
            try expand($0, context: &next)
        }
        context = next
        return result
    }
}
