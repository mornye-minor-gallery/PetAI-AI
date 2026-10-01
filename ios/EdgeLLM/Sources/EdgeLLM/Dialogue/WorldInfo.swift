import Foundation

public struct WorldInfoSettings: Codable, Equatable, Sendable {
    public let tokenBudget: Int
    public let rules: WorldInfoScanRules
    public let library: WorldInfoLibraryConfiguration?
    public let entries: [WorldInfoEntry]
    public let scanDepth: Int
    public let includeNames: Bool
    public let caseSensitive: Bool
    public let matchWholeWords: Bool
    public init(tokenBudget: Int, entries: [WorldInfoEntry], scanDepth: Int = 2,
                includeNames: Bool = true, caseSensitive: Bool = false, matchWholeWords: Bool = false, rules: WorldInfoScanRules = .init(), library: WorldInfoLibraryConfiguration? = nil) {
        self.library = library; self.rules = rules; self.tokenBudget = tokenBudget; self.entries = entries; self.scanDepth = scanDepth
        self.includeNames = includeNames; self.caseSensitive = caseSensitive; self.matchWholeWords = matchWholeWords
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tokenBudget, entries, scanDepth, includeNames, caseSensitive, matchWholeWords, rules, library
    }
    public init(from decoder: Decoder) throws {
        try rejectUnknownWorldInfoFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tokenBudget: try c.decode(Int.self, forKey: .tokenBudget),
            entries: try c.decode([WorldInfoEntry].self, forKey: .entries),
            scanDepth: try c.decodeIfPresent(Int.self, forKey: .scanDepth) ?? 2,
            includeNames: try c.decodeIfPresent(Bool.self, forKey: .includeNames) ?? true,
            caseSensitive: try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false,
            matchWholeWords: try c.decodeIfPresent(Bool.self, forKey: .matchWholeWords) ?? false,
            rules: try c.decodeIfPresent(WorldInfoScanRules.self, forKey: .rules) ?? .init(),
            library: try c.decodeIfPresent(WorldInfoLibraryConfiguration.self, forKey: .library))
    }
}

public struct WorldInfoEntry: Codable, Equatable, Sendable {
    public enum SecondaryLogic: String, Codable, Sendable { case andAny = "AND_ANY", andAll = "AND_ALL", notAny = "NOT_ANY", notAll = "NOT_ALL" }
    public enum Position: String, Codable, Sendable { case beforeCharacter = "before-character", afterCharacter = "after-character", beforeNote = "before-note", afterNote = "after-note", inChat = "in-chat", beforeExamples = "before-examples", afterExamples = "after-examples", outlet = "outlet" }
    public let id: String
    public let keys: [String]
    public var content: String
    public let rules: WorldInfoEntryRules
    public let secondaryKeys: [String]
    public let secondaryLogic: SecondaryLogic
    public let enabled: Bool
    public let constant: Bool
    public let ignoreBudget: Bool
    public let order: Int
    public let position: Position
    public let scanDepth: Int?
    public let caseSensitive: Bool?
    public let matchWholeWords: Bool?
    public init(id: String, keys: [String] = [], content: String, secondaryKeys: [String] = [],
                secondaryLogic: SecondaryLogic = .andAny, enabled: Bool = true, constant: Bool = false,
                ignoreBudget: Bool = false, order: Int = 100, position: Position = .afterCharacter,
                scanDepth: Int? = nil, caseSensitive: Bool? = nil, matchWholeWords: Bool? = nil, rules: WorldInfoEntryRules = .init()) {
        self.rules = rules; self.id = id; self.keys = keys; self.content = content; self.secondaryKeys = secondaryKeys
        self.secondaryLogic = secondaryLogic; self.enabled = enabled; self.constant = constant
        self.ignoreBudget = ignoreBudget; self.order = order; self.position = position
        self.scanDepth = scanDepth; self.caseSensitive = caseSensitive; self.matchWholeWords = matchWholeWords
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, keys, content, secondaryKeys, secondaryLogic, enabled, constant, ignoreBudget, order, position, scanDepth, caseSensitive, matchWholeWords, rules
    }
    public init(from decoder: Decoder) throws {
        try rejectUnknownWorldInfoFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), keys: try c.decodeIfPresent([String].self, forKey: .keys) ?? [],
            content: try c.decode(String.self, forKey: .content),
            secondaryKeys: try c.decodeIfPresent([String].self, forKey: .secondaryKeys) ?? [],
            secondaryLogic: try c.decodeIfPresent(SecondaryLogic.self, forKey: .secondaryLogic) ?? .andAny,
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            constant: try c.decodeIfPresent(Bool.self, forKey: .constant) ?? false,
            ignoreBudget: try c.decodeIfPresent(Bool.self, forKey: .ignoreBudget) ?? false,
            order: try c.decodeIfPresent(Int.self, forKey: .order) ?? 100,
            position: try c.decodeIfPresent(Position.self, forKey: .position) ?? .afterCharacter,
            scanDepth: try c.decodeIfPresent(Int.self, forKey: .scanDepth),
            caseSensitive: try c.decodeIfPresent(Bool.self, forKey: .caseSensitive),
            matchWholeWords: try c.decodeIfPresent(Bool.self, forKey: .matchWholeWords),
            rules: try c.decodeIfPresent(WorldInfoEntryRules.self, forKey: .rules) ?? .init())
    }
}

public enum WorldInfoError: Error, Equatable {
    case tokenMeasurerRequired, invalidBudget, invalidScanDepth, invalidID, duplicateID(String)
    case emptyKey(String), invalidRule(String)
}

public struct WorldInfoEntryTrace: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case disabled, noPrimaryMatch, secondaryMismatch, budgetExceeded, budgetStopped, selected, filtered, delayed, cooldown, recursionExcluded, probabilityFailed, groupExcluded }
    public enum Delivery: String, Codable, Sendable { case inserted, noteInactive, empty, outlet }
    public let id: String
    public let position: WorldInfoEntry.Position
    public let order: Int
    public let scanDepth: Int
    public let constant: Bool
    public let primaryMatch: String?
    public let secondaryMatches: [String]
    public let reason: Reason
    public let candidateTokens: Int?
    public let ignoreBudget: Bool
    public internal(set) var delivery: Delivery?
}

public struct WorldInfoTrace: Codable, Equatable, Sendable {
    public let tokenBudget: Int
    public let overflowed: Bool
    public let scannedMessages: Int
    public let scannedNote: Bool
    public internal(set) var entries: [WorldInfoEntryTrace]
}

public struct WorldInfoSelection: Sendable {
    /// Selection order is high priority first. Rendering reverses each destination group.
    public let selected: [WorldInfoEntry]
    public let trace: WorldInfoTrace
    public let nextState: WorldInfoState
    public let textContext: WorldInfoTextContext
    public let automationIDs: [String]
}

private struct WorldInfoCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
func rejectUnknownWorldInfoFields(_ decoder: Decoder, allowed: [String]) throws {
    let container = try decoder.container(keyedBy: WorldInfoCodingKey.self)
    if let key = container.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath + [key],
            debugDescription: "Unsupported World Info field: \(key.stringValue)"))
    }
}
