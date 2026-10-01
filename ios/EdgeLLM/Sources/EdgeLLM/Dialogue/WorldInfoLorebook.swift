import Foundation

public enum WorldInfoLorebookError: Error, Equatable, Sendable {
    case invalidName
    case invalidField(String)
    case unsupportedField(String)
    case entryIDMismatch(String)
    case missingEntry(String)
    case duplicateBook(String)
    case missingBook(String)
}

/// Imports SillyTavern's native entries object. Unmodified exports retain the original bytes.
/// Metadata is opaque and never interpreted as activation behavior; its paths are observable.
public struct WorldInfoLorebook: Sendable {
    public static let preservedEntryMetadataFields = ["comment", "addMemo", "displayIndex", "extensions"]
    public let name: String
    public let entries: [WorldInfoEntry]
    public let preservedMetadataPaths: [String]
    private let data: Data

    public init(data: Data, name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorldInfoLorebookError.invalidName }
        let root = try Self.object(data)
        guard let records = root["entries"] as? [String: Any] else { throw WorldInfoLorebookError.invalidField("entries") }
        var ordered = [(Int, WorldInfoEntry)]()
        var metadata = root.keys.filter { $0 != "entries" }
        for (key, value) in records {
            let path = "entries.\(key)"
            guard let uid = Int(key), uid >= 0, uid < Int(UInt32.max), String(uid) == key,
                  let raw = value as? [String: Any] else { throw WorldInfoLorebookError.invalidField(path) }
            let fields = LorebookFields(raw: raw, path: path)
            guard try fields.value("uid", as: Int.self) == uid else { throw WorldInfoLorebookError.invalidField("\(path).uid") }
            for field in raw.keys.sorted() where !Self.supportedFields.contains(field) {
                throw WorldInfoLorebookError.unsupportedField("\(path).\(field)")
            }
            metadata += raw.keys.filter { Self.preservedEntryMetadataFields.contains($0) }.map { "\(path).\($0)" }
            ordered.append((uid, try Self.convert(fields, id: "\(name).\(uid)")))
        }
        self.name = name
        self.data = data
        self.entries = ordered.sorted { $0.0 < $1.0 }.map(\.1)
        self.preservedMetadataPaths = metadata.sorted()
    }

    public func exportData() throws -> Data { data }

    public func replacing(_ entry: WorldInfoEntry) throws -> Self {
        guard entries.contains(where: { $0.id == entry.id }) else { throw WorldInfoLorebookError.missingEntry(entry.id) }
        return try upserting(entry)
    }

    public func upserting(_ entry: WorldInfoEntry) throws -> Self {
        let uid = try uid(for: entry.id)
        var root = try Self.object(data)
        var records = root["entries"] as? [String: Any] ?? [:]
        var raw = records[String(uid)] as? [String: Any] ?? [:]
        // Compare normalized projections, then touch only changed runtime fields. This preserves
        // dormant secondary keys, disabled probability values and source boolean encodings when
        // an unrelated field is edited, as well as comments/extensions/root metadata.
        let previous = try entries.first(where: { $0.id == entry.id }).map { try Self.originalFields($0, uid: uid) }
        for (key, value) in try Self.originalFields(entry, uid: uid) {
            if let old = previous?[key], NSDictionary(dictionary: ["value": old]) == NSDictionary(dictionary: ["value": value]) { continue }
            raw[key] = value
        }
        records[String(uid)] = raw
        root["entries"] = records
        return try Self(data: JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), name: name)
    }

    public func removing(id: String) throws -> Self {
        let uid = try uid(for: id)
        var root = try Self.object(data)
        var records = root["entries"] as? [String: Any] ?? [:]
        records.removeValue(forKey: String(uid))
        root["entries"] = records
        return try Self(data: JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), name: name)
    }

    private func uid(for id: String) throws -> Int {
        let prefix = name + "."
        guard id.hasPrefix(prefix), let uid = Int(id.dropFirst(prefix.count)), uid >= 0,
              uid < Int(UInt32.max), id == prefix + String(uid) else { throw WorldInfoLorebookError.entryIDMismatch(id) }
        return uid
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorldInfoLorebookError.invalidField("root")
        }
        return root
    }

    private static let scanFields = [
        ("matchPersonaDescription", "personaDescription"), ("matchCharacterDescription", "characterDescription"),
        ("matchCharacterPersonality", "characterPersonality"), ("matchCharacterDepthPrompt", "characterDepthPrompt"),
        ("matchScenario", "scenario"), ("matchCreatorNotes", "creatorNotes"),
    ]
    private static let positions: [WorldInfoEntry.Position] = [
        .beforeCharacter, .afterCharacter, .beforeNote, .afterNote, .inChat, .beforeExamples, .afterExamples, .outlet,
    ]
    private static let logic: [WorldInfoEntry.SecondaryLogic] = [.andAny, .notAll, .notAny, .andAll]
    private static let roles: [DialoguePromptRole] = [.system, .user, .assistant]
    private static let supportedFields: Set<String> = Set(preservedEntryMetadataFields + scanFields.map(\.0) + [
        "uid", "key", "keysecondary", "content", "constant", "vectorized", "selective", "selectiveLogic",
        "order", "position", "disable", "ignoreBudget", "excludeRecursion", "preventRecursion", "delayUntilRecursion",
        "probability", "useProbability", "depth", "outletName", "group", "groupOverride", "groupWeight", "scanDepth",
        "caseSensitive", "matchWholeWords", "useGroupScoring", "automationId", "role", "sticky", "cooldown", "delay",
        "characterFilter", "triggers",
    ])

    private static func convert(_ f: LorebookFields, id: String) throws -> WorldInfoEntry {
        let position = try f.value("position", as: Int.self) ?? 0
        let logicIndex = try f.value("selectiveLogic", as: Int.self) ?? 0
        let role = try f.value("role", as: Int.self) ?? 0
        guard positions.indices.contains(position) else { throw WorldInfoLorebookError.invalidField("\(f.path).position") }
        guard logic.indices.contains(logicIndex) else { throw WorldInfoLorebookError.invalidField("\(f.path).selectiveLogic") }
        guard roles.indices.contains(role) else { throw WorldInfoLorebookError.invalidField("\(f.path).role") }
        var rules = WorldInfoEntryRules()
        rules.excludeRecursion = try f.value("excludeRecursion", as: Bool.self)
        rules.preventRecursion = try f.value("preventRecursion", as: Bool.self)
        if let raw = f.raw["delayUntilRecursion"], !(raw is NSNull) {
            // Original JSON accepts true as recursion level 1 and false as disabled.
            if let bool = try? f.required("delayUntilRecursion", as: Bool.self) { rules.delayUntilRecursion = bool ? 1 : 0 }
            else { rules.delayUntilRecursion = try f.required("delayUntilRecursion", as: Int.self) }
        }
        let probability = try f.value("probability", as: Double.self) ?? 100
        rules.probability = (try f.value("useProbability", as: Bool.self) ?? false) ? probability : nil
        if let groups = try f.value("group", as: String.self) {
            // Match split(/,\s*/): retain initial/trailing whitespace unrelated to the comma.
            rules.groups = groups.components(separatedBy: ",").enumerated().map { index, value in
                index == 0 ? value : String(value.drop(while: { $0.isWhitespace }))
            }.filter { !$0.isEmpty }
        }
        rules.groupOverride = try f.value("groupOverride", as: Bool.self)
        rules.groupWeight = try f.value("groupWeight", as: Double.self)
        rules.groupScoring = try f.value("useGroupScoring", as: Bool.self)
        rules.sticky = try f.value("sticky", as: Int.self)
        rules.cooldown = try f.value("cooldown", as: Int.self)
        rules.delay = try f.value("delay", as: Int.self)
        rules.triggers = try f.value("triggers", as: [String].self)
        rules.vectorized = try f.value("vectorized", as: Bool.self)
        rules.depth = try f.value("depth", as: Int.self)
        rules.role = roles[role]
        rules.outlet = try f.value("outletName", as: String.self)
        rules.automationID = try f.value("automationId", as: String.self)
        var fields = [String]()
        for (source, target) in scanFields where try f.value(source, as: Bool.self) == true { fields.append(target) }
        rules.scanFields = fields
        if let raw = f.raw["characterFilter"], !(raw is NSNull) {
            guard let object = raw as? [String: Any] else { throw WorldInfoLorebookError.invalidField("\(f.path).characterFilter") }
            let filter = LorebookFields(raw: object, path: "\(f.path).characterFilter")
            for key in object.keys.sorted() where !["names", "tags", "isExclude"].contains(key) {
                throw WorldInfoLorebookError.unsupportedField("\(filter.path).\(key)")
            }
            rules.characterNames = try filter.value("names", as: [String].self)
            rules.characterTags = try filter.value("tags", as: [String].self)
            rules.excludeCharacters = try filter.value("isExclude", as: Bool.self)
        }
        let selective = try f.value("selective", as: Bool.self) ?? false
        let secondary = try f.value("keysecondary", as: [String].self) ?? []
        return WorldInfoEntry(id: id, keys: try f.value("key", as: [String].self) ?? [],
            content: try f.value("content", as: String.self) ?? "", secondaryKeys: selective ? secondary : [],
            secondaryLogic: logic[logicIndex], enabled: !(try f.value("disable", as: Bool.self) ?? false),
            constant: try f.value("constant", as: Bool.self) ?? false, ignoreBudget: try f.value("ignoreBudget", as: Bool.self) ?? false,
            order: try f.value("order", as: Int.self) ?? 100, position: positions[position],
            scanDepth: try f.value("scanDepth", as: Int.self), caseSensitive: try f.value("caseSensitive", as: Bool.self),
            matchWholeWords: try f.value("matchWholeWords", as: Bool.self), rules: rules)
    }

    private static func originalFields(_ entry: WorldInfoEntry, uid: Int) throws -> [String: Any] {
        let r = entry.rules
        guard r.replacements == nil || r.replacements?.isEmpty == true else {
            throw WorldInfoLorebookError.unsupportedField("\(entry.id).rules.replacements")
        }
        for field in r.scanFields ?? [] where !scanFields.contains(where: { $0.1 == field }) {
            throw WorldInfoLorebookError.unsupportedField("\(entry.id).rules.scanFields.\(field)")
        }
        let null = NSNull()
        var result: [String: Any] = [
            "uid": uid, "key": entry.keys, "keysecondary": entry.secondaryKeys, "content": entry.content,
            "selective": !entry.secondaryKeys.isEmpty, "selectiveLogic": logic.firstIndex(of: entry.secondaryLogic)!,
            "position": positions.firstIndex(of: entry.position)!, "disable": !entry.enabled,
            "constant": entry.constant, "ignoreBudget": entry.ignoreBudget, "order": entry.order,
            "scanDepth": entry.scanDepth.map { $0 as Any } ?? null,
            "caseSensitive": entry.caseSensitive.map { $0 as Any } ?? null,
            "matchWholeWords": entry.matchWholeWords.map { $0 as Any } ?? null,
            "useProbability": r.probability != nil, "probability": r.probability ?? 100,
            "group": (r.groups ?? []).joined(separator: ","), "groupOverride": r.groupOverride ?? false,
            "groupWeight": r.groupWeight ?? 100, "useGroupScoring": r.groupScoring.map { $0 as Any } ?? null,
            "excludeRecursion": r.excludeRecursion ?? false, "preventRecursion": r.preventRecursion ?? false,
            "delayUntilRecursion": r.delayUntilRecursion ?? 0, "sticky": r.sticky.map { $0 as Any } ?? null,
            "cooldown": r.cooldown.map { $0 as Any } ?? null, "delay": r.delay.map { $0 as Any } ?? null,
            "triggers": r.triggers ?? [], "vectorized": r.vectorized ?? false, "depth": r.depth ?? 4,
            "role": roles.firstIndex(of: r.role ?? .system)!, "outletName": r.outlet ?? "", "automationId": r.automationID ?? "",
            "characterFilter": ["names": r.characterNames ?? [], "tags": r.characterTags ?? [], "isExclude": r.excludeCharacters ?? false],
        ]
        for (source, target) in scanFields { result[source] = r.scanFields?.contains(target) ?? false }
        return result
    }
}

private struct LorebookFields {
    let raw: [String: Any]
    let path: String
    func value<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        return try required(key, as: type)
    }
    func required<T: Decodable>(_ key: String, as type: T.Type) throws -> T {
        guard let value = raw[key] else { throw WorldInfoLorebookError.invalidField("\(path).\(key)") }
        do {
            return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
        } catch { throw WorldInfoLorebookError.invalidField("\(path).\(key)") }
    }
}

/// Scope selection is pure: the host supplies the active books, character bindings and chat/persona bindings.
public struct WorldInfoLibrary: Sendable {
    public enum Scope: String, Codable, Sendable { case global, character, chat, persona }
    public enum Strategy: String, Codable, Sendable { case even, characterFirst, globalFirst }
    public let lorebooks: [WorldInfoLorebook]

    public init(lorebooks: [WorldInfoLorebook]) throws {
        var names = Set<String>()
        for book in lorebooks where !names.insert(book.name).inserted { throw WorldInfoLorebookError.duplicateBook(book.name) }
        self.lorebooks = lorebooks
    }

    public func select(global: [String] = [], character: [String] = [], chat: String? = nil,
                       persona: String? = nil, strategy: Strategy = .even) throws -> [WorldInfoEntry] {
        let globals = try collect(global)
        let chatNames = chat.map { global.contains($0) ? [] : [$0] } ?? []
        let personaNames = persona.map { global.contains($0) || $0 == chat ? [] : [$0] } ?? []
        let characters = character.filter { !global.contains($0) && $0 != chat && $0 != persona }
        let characterEntries = try collect(characters)
        let rest: [WorldInfoEntry]
        switch strategy {
        case .even: rest = sorted(globals + characterEntries)
        case .characterFirst: rest = sorted(characterEntries) + sorted(globals)
        case .globalFirst: rest = sorted(globals) + sorted(characterEntries)
        }
        return try sorted(collect(chatNames)) + sorted(collect(personaNames)) + rest
    }

    private func collect(_ names: [String]) throws -> [WorldInfoEntry] {
        var seen = Set<String>()
        var result = [WorldInfoEntry]()
        for name in names where seen.insert(name).inserted {
            guard let book = lorebooks.first(where: { $0.name == name }) else { throw WorldInfoLorebookError.missingBook(name) }
            result += book.entries
        }
        return result
    }

    private func sorted(_ entries: [WorldInfoEntry]) -> [WorldInfoEntry] {
        // Explicit tie-break preserves upstream's stable input ordering across book boundaries.
        entries.enumerated().sorted {
            $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order > $1.element.order
        }.map(\.element)
    }
}
