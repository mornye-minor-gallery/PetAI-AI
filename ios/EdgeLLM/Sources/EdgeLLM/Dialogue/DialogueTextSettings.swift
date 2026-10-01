import Foundation

/// Host metadata is separate from persistent macro variables. Evaluation records these inputs.
public struct DialogueTextSettings: Codable, Equatable, Sendable {
    public var runtime: [String:JSONValue]
    public var regex: DialogueRegexSettings?
    public init(runtime: [String:JSONValue] = [:], regex: DialogueRegexSettings? = nil) {
        self.runtime = runtime; self.regex = regex
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case runtime, regex }
    public init(from decoder: Decoder) throws {
        try rejectUnknownWorldInfoFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy:CodingKeys.self)
        runtime = try c.decodeIfPresent([String:JSONValue].self,forKey:.runtime) ?? [:]
        regex = try c.decodeIfPresent(DialogueRegexSettings.self,forKey:.regex)
    }
}
