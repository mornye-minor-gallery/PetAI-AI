import Foundation

extension DialogueMacroEvaluator {
    func simpleField(_ name: String) -> String? {
        switch name.lowercased() {
        case "user": return context.user
        case "char": return context.char
        case "description", "chardescription": return context.description
        case "personality", "charpersonality": return context.personality
        case "scenario", "charscenario": return context.scenario
        case "persona": return context.persona
        case "group", "charifnotgroup": return host("group") ?? context.char
        case "groupnotmuted": return host("groupNotMuted") ?? context.char
        case "notchar": return host("notChar") ?? context.user
        case "model": return host("model") ?? ""
        case "original": return host("original") ?? ""
        case "input": return host("input") ?? ""
        case "ismobile": return host("isMobile") ?? "false"
        case "lastgenerationtype": return host("lastGenerationType") ?? ""
        case "maxprompt", "maxprompttokens": return host("inputTokens") ?? "0"
        case "maxcontext", "maxcontexttokens": return host("contextTokens") ?? "0"
        case "maxresponse", "maxresponsetokens": return host("outputTokens") ?? "0"
        case "charprompt": return character("charPrompt")
        case "charinstruction": return character("charInstruction")
        case "chardepthprompt": return character("charDepthPrompt")
        case "creatornotes", "charcreatornotes": return character("creatorNotes")
        case "version", "charversion", "char_version": return character("version")
        case "mesexamplesraw": return character("mesExamplesRaw")
        case "mesexamples": return host("formattedExamples") ?? character("mesExamplesRaw")
        case "firstincludedmessageid": return host("firstIncludedMessageID") ?? ""
        case "firstdisplayedmessageid": return host("firstDisplayedMessageID") ?? ""
        case "allchatrange": return messages.isEmpty ? "" : "0-\(messages.count-1)"
        case "lastmessage", "lastusermessage", "lastcharmessage", "lastmessageid", "lastswipeid", "currentswipeid":
            let eligible = messages.enumerated().filter { _, message in
                if name == "lastusermessage" { return message["is_user"] == .bool(true) && message["is_system"] != .bool(true) }
                if name == "lastcharmessage" { return message["is_user"] != .bool(true) && message["is_system"] != .bool(true) }
                return true
            }
            guard let last = eligible.last else { return "" }
            if name == "lastmessageid" { return String(last.offset) }
            if name == "currentswipeid", case .number(let id) = last.element["swipe_id"] { return Self.number(id+1) }
            if name == "lastswipeid", case .array(let swipes) = last.element["swipes"] { return String(swipes.count) }
            if name.hasSuffix("swipeid") { return "" }
            return last.element["mes"].map(scalar) ?? ""
        default: return nil
        }
    }
    var messages: [[String:JSONValue]] {
        guard case .array(let values) = context.runtime?["messages"] else { return [] }
        return values.compactMap { if case .object(let object) = $0 { return object }; return nil }
    }
    func instructField(_ name: String) -> String? {
        let keys = ["instructstorystringprefix":"story_string_prefix", "instructstorystringsuffix":"story_string_suffix",
            "instructuserprefix":"input_sequence", "instructinput":"input_sequence", "instructusersuffix":"input_suffix",
            "instructassistantprefix":"output_sequence", "instructoutput":"output_sequence", "instructassistantsuffix":"output_suffix",
            "instructseparator":"output_suffix", "instructsystemprefix":"system_sequence", "instructsystemsuffix":"system_suffix",
            "instructfirstassistantprefix":"first_output_sequence", "instructfirstoutputprefix":"first_output_sequence",
            "instructlastassistantprefix":"last_output_sequence", "instructlastoutputprefix":"last_output_sequence",
            "instructsysteminstructionprefix":"last_system_sequence",
            "instructfirstuserprefix":"first_input_sequence", "instructfirstinput":"first_input_sequence",
            "instructlastuserprefix":"last_input_sequence", "instructlastinput":"last_input_sequence",
            "instructstop":"stop_sequence", "instructuserfiller":"user_alignment_message"]
        if let key = keys[name] {
            guard case .object(let settings) = context.runtime?["instruct"], settings["enabled"] == .bool(true) else { return "" }
            if let value = settings[key], scalar(value) != "" { return scalar(value) }
            if key == "first_output_sequence" || key == "last_output_sequence" { return settings["output_sequence"].map(scalar) ?? "" }
            if key == "first_input_sequence" || key == "last_input_sequence" { return settings["input_sequence"].map(scalar) ?? "" }
            return ""
        }
        if ["exampleseparator", "chatstart"].contains(name) {
            guard case .object(let settings) = context.runtime?["contextTemplate"] else { return "" }
            return settings[name == "chatstart" ? "chat_start" : "example_separator"].map(scalar) ?? ""
        }
        if name == "systemprompt", !character("charPrompt").isEmpty { return character("charPrompt") }
        if ["system", "systemprompt", "defaultsystemprompt", "instructsystem", "instructsystemprompt"].contains(name) {
            guard case .object(let settings) = context.runtime?["systemPrompt"], settings["enabled"] == .bool(true) else { return "" }
            return settings["content"].map(scalar) ?? ""
        }
        return nil
    }
}
