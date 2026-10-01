import Foundation

public enum WorldInfoImportError: Error, Equatable {
    case invalidFormat, missingLorebook, invalidPNG, missingMetadata, duplicateID(Int)
}
public struct WorldInfoImportResult: Sendable {
    public let lorebook: WorldInfoLorebook
    public let character: [String: JSONValue]?
    public let format: String
}

/// Pure native conversion of the pinned upstream import formats. Original metadata is retained.
public enum WorldInfoImport {
    /// JSON wire transport preserves PNG bytes without implementing conversion in Python.
    public static func read(encoded: String, name: String) throws -> WorldInfoImportResult {
        let prefix = "data:image/png;base64,"
        if encoded.hasPrefix(prefix) {
            guard let data = Data(base64Encoded:String(encoded.dropFirst(prefix.count))) else { throw WorldInfoImportError.invalidPNG }
            return try read(data:data,name:name)
        }
        return try read(data:Data(encoded.utf8),name:name)
    }
    public static func read(data: Data, name: String) throws -> WorldInfoImportResult {
        let bytes = data.starts(with: PNGTextMetadata.signature) ? try PNGTextMetadata.json(data) : data
        guard let input = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw WorldInfoImportError.invalidFormat }
        var root = input, character: [String:JSONValue]?, format = "native"
        if let card = input["data"] as? [String:Any], let book = card["character_book"] as? [String:Any] {
            root = book; format = "character"
            character = try JSONDecoder().decode([String:JSONValue].self,from:JSONSerialization.data(withJSONObject:card))
        } else if let book = input["character_book"] as? [String:Any] {
            root = book; format = "character"
            character = try JSONDecoder().decode([String:JSONValue].self,from:bytes)
        } else if input["lorebookVersion"] != nil { format = "novel" }
        else if input["kind"] as? String == "memory" { format = "agnai" }
        else if input["type"] as? String == "risu" { format = "risu" }
        else if input["entries"] is [[String:Any]] { format = "character" }
        else if input["spec"] != nil { throw WorldInfoImportError.missingLorebook }
        if format == "native" { return .init(lorebook:try .init(data:bytes,name:name),character:nil,format:format) }
        guard let entries = root[format == "risu" ? "data" : "entries"] as? [[String:Any]] else { throw WorldInfoImportError.invalidFormat }
        var converted: [String:Any] = [:]
        for (index,entry) in entries.enumerated() {
            let uid: Int
            if format == "character", let raw = entry["id"] {
                guard let n = raw as? Int, n >= 0, n < Int(UInt32.max) else { throw WorldInfoImportError.invalidFormat }; uid = n
            } else { uid = index }
            guard converted[String(uid)] == nil else { throw WorldInfoImportError.duplicateID(uid) }
            var value: [String:Any] = ["uid":uid,"keysecondary":[],"constant":false,"selective":false,"vectorized":false,
                "position":0,"selectiveLogic":0,"probability":100,"useProbability":true,"displayIndex":index,
                "excludeRecursion":false,"preventRecursion":false,"delayUntilRecursion":false,
                "group":"","groupOverride":false,"groupWeight":100,"triggers":[],"depth":4,"outletName":"","automationId":""]
            switch format {
            case "agnai":
                value["key"] = entry["keywords"]; value["content"] = entry["entry"]; value["comment"] = entry["name"]
                value["order"] = entry["weight"]; value["disable"] = !(entry["enabled"] as? Bool ?? false)
                value["addMemo"] = !(entry["name"] as? String ?? "").isEmpty
            case "novel":
                value["key"] = entry["keys"]; value["content"] = entry["text"]; value["comment"] = entry["displayName"] ?? ""
                value["order"] = (entry["contextConfig"] as? [String:Any])?["budgetPriority"] ?? 0
                value["disable"] = !(entry["enabled"] as? Bool ?? false)
                value["addMemo"] = !(entry["displayName"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
            case "risu":
                guard let key = entry["key"] as? String else { throw WorldInfoImportError.invalidFormat }
                value["key"] = key.components(separatedBy:",").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
                if let key = entry["secondkey"] as? String, !key.isEmpty { value["keysecondary"] = key.components(separatedBy:",").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) } }
                value["content"] = entry["content"]; value["comment"] = entry["comment"]
                value["constant"] = entry["alwaysActive"]; value["selective"] = entry["selective"]; value["order"] = entry["insertorder"]
                value["disable"] = false; value["addMemo"] = true
                if let probability = entry["activationPercent"], !(probability is NSNull) {
                    guard let n = probability as? NSNumber else { throw WorldInfoImportError.invalidFormat }
                    value["probability"] = n; value["useProbability"] = n.doubleValue != 0
                }
            default:
                let ext = entry["extensions"] as? [String:Any] ?? [:]
                value["key"] = entry["keys"]; value["keysecondary"] = entry["secondary_keys"] ?? []
                value["content"] = entry["content"]; value["comment"] = entry["comment"] ?? ""
                value["constant"] = entry["constant"] ?? false; value["selective"] = entry["selective"] ?? false
                value["order"] = entry["insertion_order"]; value["disable"] = !(entry["enabled"] as? Bool ?? false)
                value["position"] = entry["position"] as? String == "before_char" ? 0 : 1
                value["extensions"] = ext; value["addMemo"] = !(entry["comment"] as? String ?? "").isEmpty
                for (source,target) in characterExtensions where ext[source] != nil && !(ext[source] is NSNull) { value[target] = ext[source] }
            }
            converted[String(uid)] = value
        }
        var output: [String:Any] = ["entries":converted]
        if format == "character" { output["originalData"] = root }
        return .init(lorebook:try .init(data:JSONSerialization.data(withJSONObject:output,options:.sortedKeys),name:name),character:character,format:format)
    }
    private static let characterExtensions = [
        "position":"position","exclude_recursion":"excludeRecursion","prevent_recursion":"preventRecursion",
        "delay_until_recursion":"delayUntilRecursion","display_index":"displayIndex","probability":"probability",
        "useProbability":"useProbability","depth":"depth","selectiveLogic":"selectiveLogic","outlet_name":"outletName",
        "group":"group","group_override":"groupOverride","group_weight":"groupWeight","scan_depth":"scanDepth",
        "case_sensitive":"caseSensitive","match_whole_words":"matchWholeWords","use_group_scoring":"useGroupScoring",
        "automation_id":"automationId","role":"role","vectorized":"vectorized","sticky":"sticky","cooldown":"cooldown",
        "delay":"delay","match_persona_description":"matchPersonaDescription","match_character_description":"matchCharacterDescription",
        "match_character_personality":"matchCharacterPersonality","match_character_depth_prompt":"matchCharacterDepthPrompt",
        "match_scenario":"matchScenario","match_creator_notes":"matchCreatorNotes","triggers":"triggers","ignore_budget":"ignoreBudget",
    ]
}
