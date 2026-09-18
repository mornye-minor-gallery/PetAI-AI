import Foundation

/// Optional values inherit engine defaults. Separate from text so game state never
/// needs to be expressed as instructions to the language model.
public struct WorldInfoScanRules: Codable, Equatable, Sendable {
    public var vector: WorldInfoVectorSettings?
    public var recursive: Bool?
    public var maximumSteps: Int?
    public var minimumActivations: Int?
    public var maximumDepth: Int?
    public var budgetPercent: Double?
    public var budgetCap: Int?
    public var groupScoring: Bool?
    public init() {}
    private enum CodingKeys: String, CodingKey, CaseIterable { case vector, recursive, maximumSteps, minimumActivations, maximumDepth, budgetPercent, budgetCap, groupScoring }
    public init(from decoder: Decoder) throws {
        try rejectUnknownWorldInfoFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vector = try c.decodeIfPresent(WorldInfoVectorSettings.self, forKey: .vector)
        recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive)
        maximumSteps = try c.decodeIfPresent(Int.self, forKey: .maximumSteps)
        minimumActivations = try c.decodeIfPresent(Int.self, forKey: .minimumActivations)
        maximumDepth = try c.decodeIfPresent(Int.self, forKey: .maximumDepth)
        budgetPercent = try c.decodeIfPresent(Double.self, forKey: .budgetPercent)
        budgetCap = try c.decodeIfPresent(Int.self, forKey: .budgetCap)
        groupScoring = try c.decodeIfPresent(Bool.self, forKey: .groupScoring)
    }

}

public struct WorldInfoEntryRules: Codable, Equatable, Sendable {
    public var excludeRecursion: Bool?
    public var preventRecursion: Bool?
    public var delayUntilRecursion: Int?
    public var probability: Double?
    public var groups: [String]?
    public var groupOverride: Bool?
    public var groupWeight: Double?
    public var groupScoring: Bool?
    public var sticky: Int?
    public var cooldown: Int?
    public var delay: Int?
    public var characterNames: [String]?
    public var characterTags: [String]?
    public var excludeCharacters: Bool?
    public var triggers: [String]?
    public var scanFields: [String]?
    public var vectorized: Bool?
    public var depth: Int?
    public var role: DialoguePromptRole?
    public var outlet: String?
    public var automationID: String?
    public var replacements: [WorldInfoReplacement]?
    public init() {}
    private enum CodingKeys: String, CodingKey, CaseIterable { case excludeRecursion, preventRecursion, delayUntilRecursion, probability, groups, groupOverride, groupWeight, groupScoring, sticky, cooldown, delay, characterNames, characterTags, excludeCharacters, triggers, scanFields, vectorized, depth, role, outlet, automationID, replacements }
    public init(from decoder: Decoder) throws {
        try rejectUnknownWorldInfoFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        excludeRecursion = try c.decodeIfPresent(Bool.self, forKey: .excludeRecursion)
        preventRecursion = try c.decodeIfPresent(Bool.self, forKey: .preventRecursion)
        delayUntilRecursion = try c.decodeIfPresent(Int.self, forKey: .delayUntilRecursion)
        probability = try c.decodeIfPresent(Double.self, forKey: .probability)
        groups = try c.decodeIfPresent([String].self, forKey: .groups)
        groupOverride = try c.decodeIfPresent(Bool.self, forKey: .groupOverride)
        groupWeight = try c.decodeIfPresent(Double.self, forKey: .groupWeight)
        groupScoring = try c.decodeIfPresent(Bool.self, forKey: .groupScoring)
        sticky = try c.decodeIfPresent(Int.self, forKey: .sticky)
        cooldown = try c.decodeIfPresent(Int.self, forKey: .cooldown)
        delay = try c.decodeIfPresent(Int.self, forKey: .delay)
        characterNames = try c.decodeIfPresent([String].self, forKey: .characterNames)
        characterTags = try c.decodeIfPresent([String].self, forKey: .characterTags)
        excludeCharacters = try c.decodeIfPresent(Bool.self, forKey: .excludeCharacters)
        triggers = try c.decodeIfPresent([String].self, forKey: .triggers)
        scanFields = try c.decodeIfPresent([String].self, forKey: .scanFields)
        vectorized = try c.decodeIfPresent(Bool.self, forKey: .vectorized)
        depth = try c.decodeIfPresent(Int.self, forKey: .depth)
        role = try c.decodeIfPresent(DialoguePromptRole.self, forKey: .role)
        outlet = try c.decodeIfPresent(String.self, forKey: .outlet)
        automationID = try c.decodeIfPresent(String.self, forKey: .automationID)
        replacements = try c.decodeIfPresent([WorldInfoReplacement].self, forKey: .replacements)
    }

}
public struct WorldInfoReplacement: Codable, Equatable, Sendable {
    public var pattern: String
    public var replacement: String
    public init(pattern: String, replacement: String) { self.pattern = pattern; self.replacement = replacement }
}

public struct WorldInfoContext: Codable, Equatable, Sendable {
    public var characterName: String = ""
    public var characterTags: [String] = []
    public var trigger: String = "normal"
    public var scanFields: [String: String] = [:]
    public var externallyActivated: [String] = []
    /// Retrieval is supplied by the host; the selection engine never performs I/O.
    public var vectorMatches: [String] = []
    public var messageNumber: Int = 1
    public var contextTokens: Int = 8096
    public var randomSeed: UInt64 = 1
    public init() {}
    private enum CodingKeys: String, CodingKey, CaseIterable { case characterName, characterTags, trigger, scanFields, externallyActivated, vectorMatches, messageNumber, contextTokens, randomSeed }
    public init(from decoder: Decoder) throws {
        try rejectUnknownWorldInfoFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        characterName = try c.decodeIfPresent(String.self, forKey: .characterName) ?? ""
        characterTags = try c.decodeIfPresent([String].self, forKey: .characterTags) ?? []
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? "normal"
        scanFields = try c.decodeIfPresent([String: String].self, forKey: .scanFields) ?? [:]
        externallyActivated = try c.decodeIfPresent([String].self, forKey: .externallyActivated) ?? []
        vectorMatches = try c.decodeIfPresent([String].self, forKey: .vectorMatches) ?? []
        messageNumber = try c.decodeIfPresent(Int.self, forKey: .messageNumber) ?? 1
        contextTokens = try c.decodeIfPresent(Int.self, forKey: .contextTokens) ?? 8096
        randomSeed = try c.decodeIfPresent(UInt64.self, forKey: .randomSeed) ?? 1
    }

}

/// Explicit seed makes probability and group choices reproducible without a global RNG.
struct WorldInfoRandom {
    var state: UInt64
    mutating func next() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z ^= z >> 31
        return Double(z >> 11) / 9007199254740992.0
    }
}
