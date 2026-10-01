import EdgeLLM
import Foundation

public struct ProductPromptSnapshot: Codable, Equatable, Sendable {
    public let configurationID: String
    public let systemPrompt: String
    public let temperature: Float
    public let topK: Int
    public let topP: Float
    public let maxOutputTokens: Int
    public let thinkingEnabled: Bool

    public init(content: DialogueContent) throws {
        let configuration = SLMConfiguration.production
        configurationID = configuration.id
        systemPrompt = content.promptSet.responseSystemPrompt(
            activeCard: nil, userProfileContext: UserProfileContext(characterName: content.name))
        temperature = configuration.generation.responseSampling.temperature
        topK = configuration.generation.responseSampling.samplerTopK
        topP = configuration.generation.responseSampling.topP
        maxOutputTokens = configuration.dialogueBudget.outputTokens
        thinkingEnabled = configuration.generation.responseThinkingDefault
    }
}

public struct RawResponseRecord: Codable, Equatable, Sendable {
    public let caseID: String
    public let rawText: String

    enum CodingKeys: String, CodingKey {
        case caseID = "case_id"
        case rawText = "raw_text"
    }
}

public struct NormalizedResponseRecord: Codable, Equatable, Sendable {
    public let caseID: String
    public let rawText: String
    public let visibleText: String
    public let controlText: String
    public let headerSyntax: String
    public let memoryDecision: String?

    enum CodingKeys: String, CodingKey {
        case caseID = "case_id"
        case rawText = "raw_text"
        case visibleText = "visible_text"
        case controlText = "control_text"
        case headerSyntax = "header_syntax"
        case memoryDecision = "memory_decision"
    }
}

public enum ProductResponseNormalizer {
    public static func normalize(
        _ record: RawResponseRecord
    ) -> NormalizedResponseRecord {
        var gate = MemoryHeaderGate()
        _ = gate.consume(record.rawText)
        let result = gate.finish()
        return NormalizedResponseRecord(
            caseID: record.caseID,
            rawText: result.rawText,
            visibleText: result.visibleText,
            controlText: result.controlText,
            headerSyntax: result.syntax.rawValue,
            memoryDecision: result.decision?.rawValue
        )
    }
}
