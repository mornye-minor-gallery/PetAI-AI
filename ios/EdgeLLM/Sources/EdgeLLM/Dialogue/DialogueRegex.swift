import Foundation

/// Field names and placement numbers match SillyTavern regex JSON exports.
public struct DialogueRegexScript: Codable, Equatable, Sendable {
    public var id: String?
    public var scriptName: String?
    public var findRegex: String
    public var replaceString: String
    public var trimStrings: [String] = []
    public var placement: [Int] = [5]
    public var disabled: Bool = false
    public var markdownOnly: Bool = false
    public var promptOnly: Bool = false
    public var runOnEdit: Bool = false
    public var substituteRegex: Int = 0
    public var minDepth: Int?
    public var maxDepth: Int?
    public init(findRegex: String, replaceString: String) {
        self.findRegex = findRegex; self.replaceString = replaceString
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, scriptName, findRegex, replaceString, trimStrings, placement, disabled, markdownOnly, promptOnly, runOnEdit, substituteRegex, minDepth, maxDepth }
    public init(from decoder: Decoder) throws {
        try rejectUnknownWorldInfoFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decodeIfPresent(String.self,forKey:.id)
        scriptName = try c.decodeIfPresent(String.self,forKey:.scriptName)
        findRegex = try c.decodeIfPresent(String.self,forKey:.findRegex) ?? ""
        replaceString = try c.decodeIfPresent(String.self,forKey:.replaceString) ?? ""
        trimStrings = try c.decodeIfPresent([String].self,forKey:.trimStrings) ?? []
        placement = try c.decodeIfPresent([Int].self,forKey:.placement) ?? []
        disabled = try c.decodeIfPresent(Bool.self,forKey:.disabled) ?? false
        markdownOnly = try c.decodeIfPresent(Bool.self,forKey:.markdownOnly) ?? false
        promptOnly = try c.decodeIfPresent(Bool.self,forKey:.promptOnly) ?? false
        runOnEdit = try c.decodeIfPresent(Bool.self,forKey:.runOnEdit) ?? false
        substituteRegex = try c.decodeIfPresent(Int.self,forKey:.substituteRegex) ?? 0
        minDepth = try c.decodeIfPresent(Int.self,forKey:.minDepth)
        maxDepth = try c.decodeIfPresent(Int.self,forKey:.maxDepth)
    }

}
public struct DialogueRegexSettings: Codable, Equatable, Sendable {
    public var global: [DialogueRegexScript] = []
    public var preset: [DialogueRegexScript] = []
    public var character: [DialogueRegexScript] = []
    public var presetAllowed: Bool = false
    public var characterAllowed: Bool = false
    public var disabled: Bool = false
    public init() {}
    private enum CodingKeys: String, CodingKey, CaseIterable { case global, preset, character, presetAllowed, characterAllowed, disabled }
    public init(from decoder: Decoder) throws {
        try rejectUnknownWorldInfoFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy:CodingKeys.self)
        global = try c.decodeIfPresent([DialogueRegexScript].self,forKey:.global) ?? []
        preset = try c.decodeIfPresent([DialogueRegexScript].self,forKey:.preset) ?? []
        character = try c.decodeIfPresent([DialogueRegexScript].self,forKey:.character) ?? []
        presetAllowed = try c.decodeIfPresent(Bool.self,forKey:.presetAllowed) ?? false
        characterAllowed = try c.decodeIfPresent(Bool.self,forKey:.characterAllowed) ?? false
        disabled = try c.decodeIfPresent(Bool.self,forKey:.disabled) ?? false
    }

}
public struct DialogueRegexRequest: Codable, Sendable {
    public var placement: Int
    public var isMarkdown: Bool = false
    public var isPrompt: Bool = false
    public var isEdit: Bool = false
    public var depth: Int?
    public var characterOverride: String?
    public init(placement: Int) { self.placement = placement }
}
public enum DialogueRegex {
    public static func apply(_ text: String, request: DialogueRegexRequest,
                             context: inout WorldInfoTextContext) throws -> String {
        guard let settings = context.regex, !settings.disabled, !text.isEmpty else { return text }
        let scripts = settings.global + (settings.presetAllowed ? settings.preset : [])
            + (settings.characterAllowed ? settings.character : [])
        var next = context, result = text
        for script in scripts where !script.disabled && script.placement.contains(request.placement) {
            guard (script.markdownOnly && request.isMarkdown) || (script.promptOnly && request.isPrompt)
                || (!script.markdownOnly && !script.promptOnly && !request.isMarkdown && !request.isPrompt) else { continue }
            if request.isEdit && !script.runOnEdit { continue }
            if let depth = request.depth {
                if let min = script.minDepth, min >= -1, depth < min { continue }
                if let max = script.maxDepth, max >= 0, depth > max { continue }
            }
            var pattern = script.findRegex
            if script.substituteRegex != 0 {
                var evaluator = DialogueMacroEvaluator(context: next, original: pattern)
                evaluator.escapeResults = script.substituteRegex == 2
                pattern = try evaluator.render(DialogueMacroParser.parse(pattern))
                next = evaluator.context
            }
            result = try DialogueNativeRegex.replacing(result, pattern: pattern, replacement: script.replaceString,
                filterCapture: { captured in
                    var result = captured
                    for trim in script.trimStrings {
                        let character = next.char
                        next.char = request.characterOverride ?? character
                        let expanded: String
                        do { expanded = try WorldInfoText.expand(trim, context: &next) }
                        catch { next.char = character; throw error }
                        next.char = character
                        if !expanded.isEmpty { result = result.replacingOccurrences(of: expanded, with: "") }
                    }
                    return result
                }, transform: { try WorldInfoText.expand($0, context: &next) })
        }
        context = next
        return result
    }
}
