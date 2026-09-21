import Foundation

/// Authored content, independent of session history, memory retrieval and routing.
public struct DialogueContent: Codable, Equatable, Sendable {
    public struct Example: Codable, Equatable, Sendable {
        public let user: String
        public let assistant: String
    }
    public struct Retrieval: Codable, Equatable, Sendable {
        public let reactions: Bool
        public let worldLore: Bool
    }
    public let retrieval: Retrieval?
    public let id: String
    public let name: String
    public let persona: String
    public let situation: String
    public let knowledge: String
    public let examples: [Example]

    private enum CodingKeys: String, CodingKey {
        case id, name, persona, situation, knowledge, examples, retrieval
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retrieval = try c.decodeIfPresent(Retrieval.self, forKey: .retrieval)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        persona = try c.decode(String.self, forKey: .persona)
        situation = try c.decodeIfPresent(String.self, forKey: .situation) ?? ""
        knowledge = try c.decodeIfPresent(String.self, forKey: .knowledge) ?? ""
        examples = try c.decodeIfPresent([Example].self, forKey: .examples) ?? []
        for (key, value) in [("id", id), ("name", name), ("persona", persona)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Dialogue content requires nonempty \(key)"))
            }
        }
    }

    public static func load(data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    public static func load(url: URL) throws -> Self {
        try load(data: Data(contentsOf: url))
    }

    public static func bundled() throws -> Self { try load(url: bundledURL()) }

    public static func bundledURL() throws -> URL {
        // Unity copies resources into its framework, the lab app into its main bundle.
        for bundle in [Bundle.main, Bundle(for: DialogueContentBundleToken.self)] {
            if let url = bundle.url(forResource: "dialogue-content", withExtension: "json", subdirectory: "EdgeLLMPrompts")
                ?? bundle.url(forResource: "dialogue-content", withExtension: "json") {
                return url
            }
        }
        throw RoutedPersonaPromptRegistryError.notConfigured
    }

    public var promptSet: RoutedPersonaPromptSet {
        let sections = [("캐릭터", persona), ("현재 상황", situation), ("현재 알고 있는 정보", knowledge)]
        return .init(core: sections.filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "## \($0.0)\n\($0.1.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "\n\n"))
    }

    public var exampleDialogue: String {
        guard !examples.isEmpty else { return "" }
        return "## 말투 예시 (실제로 있었던 대화가 아님)\n" + examples
            .map { "user: \($0.user)\nassistant: \($0.assistant)" }.joined(separator: "\n\n")
    }
}

private final class DialogueContentBundleToken {}
