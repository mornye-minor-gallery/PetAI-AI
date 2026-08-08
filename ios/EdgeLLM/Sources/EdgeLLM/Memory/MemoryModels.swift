import Foundation

public enum MemoryLabel: String, Codable, CaseIterable, Sendable {
    case preference
    case event
}

public enum MemoryGateLabel: String, Codable, Sendable {
    case none
    case preference
    case event
    case both
}

public enum MemoryObservationState: String, Codable, Sendable {
    case active
    case deleted
}

public enum MemoryLabelSource: String, Codable, Sendable {
    case regex
    case prototype
    case regexAndPrototype = "regex+prototype"
    case futureMLP = "future_mlp"
    case gemmaHeader = "gemma_header"
}

public struct MemoryScope: Codable, Equatable, Hashable, Sendable {
    public let userID: String
    public let characterID: String

    public init(userID: String, characterID: String) {
        self.userID = userID
        self.characterID = characterID
    }
}

public struct MemoryWriteRequest: Equatable, Sendable {
    public let sourceMessageID: String
    public let sessionID: String
    public let scope: MemoryScope
    public let rawText: String
    public let occurredAt: Date

    public init(
        sourceMessageID: String,
        sessionID: String,
        scope: MemoryScope,
        rawText: String,
        occurredAt: Date = Date()
    ) {
        self.sourceMessageID = sourceMessageID
        self.sessionID = sessionID
        self.scope = scope
        self.rawText = rawText
        self.occurredAt = occurredAt
    }
}

public struct MemoryConversationTurn: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let sequence: Int
    public let scope: MemoryScope
    public let rawText: String
    public let occurredAt: Date
    public let contentHash: String

    public init(
        id: String,
        sessionID: String,
        sequence: Int,
        scope: MemoryScope,
        rawText: String,
        occurredAt: Date,
        contentHash: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.scope = scope
        self.rawText = rawText
        self.occurredAt = occurredAt
        self.contentHash = contentHash
    }
}

public struct MemoryRegexGateResult: Codable, Equatable, Sendable {
    public let preferenceHit: Bool
    public let eventHit: Bool
    public let hardIgnore: Bool
    public let matchedPatterns: [String]

    public init(
        preferenceHit: Bool,
        eventHit: Bool,
        hardIgnore: Bool = false,
        matchedPatterns: [String] = []
    ) {
        self.preferenceHit = preferenceHit
        self.eventHit = eventHit
        self.hardIgnore = hardIgnore
        self.matchedPatterns = matchedPatterns
    }
}

public struct MemoryGateDecision: Codable, Equatable, Sendable {
    public let label: MemoryGateLabel
    public let regex: MemoryRegexGateResult
    public let preferenceScore: Float?
    public let eventScore: Float?
    public let preferenceThreshold: Float
    public let eventThreshold: Float
    public let classifierVersion: String
    public let embeddingModelID: String?

    public var observationLabels: [MemoryLabel] {
        switch label {
        case .none:
            []
        case .preference:
            [.preference]
        case .event:
            [.event]
        case .both:
            [.preference, .event]
        }
    }

    public init(
        label: MemoryGateLabel,
        regex: MemoryRegexGateResult,
        preferenceScore: Float?,
        eventScore: Float?,
        preferenceThreshold: Float,
        eventThreshold: Float,
        classifierVersion: String,
        embeddingModelID: String?
    ) {
        self.label = label
        self.regex = regex
        self.preferenceScore = preferenceScore
        self.eventScore = eventScore
        self.preferenceThreshold = preferenceThreshold
        self.eventThreshold = eventThreshold
        self.classifierVersion = classifierVersion
        self.embeddingModelID = embeddingModelID
    }

    public func evidence(for label: MemoryLabel) -> MemoryLabelEvidence {
        let regexHit = label == .preference
            ? regex.preferenceHit
            : regex.eventHit
        let score = label == .preference
            ? preferenceScore
            : eventScore
        let source: MemoryLabelSource
        if classifierVersion.hasPrefix("gemma-header:") {
            source = .gemmaHeader
        } else if classifierVersion.hasPrefix("mlp:") {
            source = .futureMLP
        } else if regexHit, score != nil {
            source = .regexAndPrototype
        } else if regexHit {
            source = .regex
        } else {
            source = .prototype
        }
        return MemoryLabelEvidence(
            label: label,
            score: score,
            source: source,
            classifierVersion: classifierVersion
        )
    }

    public static func taggedChat(
        _ label: MemoryGateLabel,
        version: String = "wrapped-axes-v1"
    ) -> MemoryGateDecision {
        MemoryGateDecision(
            label: label,
            regex: MemoryRegexGateResult(
                preferenceHit:
                    label == .preference || label == .both,
                eventHit:
                    label == .event || label == .both
            ),
            preferenceScore: nil,
            eventScore: nil,
            preferenceThreshold: 0,
            eventThreshold: 0,
            classifierVersion: "gemma-header:\(version)",
            embeddingModelID: nil
        )
    }
}

public struct MemoryGateResult: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let turnID: String
    public let decision: MemoryGateDecision
    public let createdAt: Date

    public init(
        id: String,
        turnID: String,
        decision: MemoryGateDecision,
        createdAt: Date
    ) {
        self.id = id
        self.turnID = turnID
        self.decision = decision
        self.createdAt = createdAt
    }
}

public struct MemoryLabelEvidence: Codable, Equatable, Sendable {
    public let label: MemoryLabel
    public let score: Float?
    public let source: MemoryLabelSource
    public let classifierVersion: String

    public init(
        label: MemoryLabel,
        score: Float?,
        source: MemoryLabelSource,
        classifierVersion: String
    ) {
        self.label = label
        self.score = score
        self.source = source
        self.classifierVersion = classifierVersion
    }
}

public struct MemoryObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let turnID: String
    public let sessionID: String
    public let sequence: Int
    public let scope: MemoryScope
    public let occurredAt: Date
    public let rawText: String
    public let labelEvidence: [MemoryLabelEvidence]
    public let state: MemoryObservationState
    public let createdAt: Date

    public var labels: [MemoryLabel] {
        labelEvidence.map(\.label)
    }

    public init(
        id: String,
        turnID: String,
        sessionID: String,
        sequence: Int,
        scope: MemoryScope,
        occurredAt: Date,
        rawText: String,
        labelEvidence: some Sequence<MemoryLabelEvidence>,
        state: MemoryObservationState = .active,
        createdAt: Date
    ) {
        self.id = id
        self.turnID = turnID
        self.sessionID = sessionID
        self.sequence = sequence
        self.scope = scope
        self.occurredAt = occurredAt
        self.rawText = rawText
        self.labelEvidence = Array(labelEvidence).sorted {
            $0.label.rawValue < $1.label.rawValue
        }
        self.state = state
        self.createdAt = createdAt
    }
}

public struct MemoryObservationEmbedding: Equatable, Sendable {
    public let observationID: String
    public let modelID: String
    public let vector: [Float]
    public let createdAt: Date

    public var dimension: Int {
        vector.count
    }

    public init(
        observationID: String,
        modelID: String,
        vector: [Float],
        createdAt: Date
    ) {
        self.observationID = observationID
        self.modelID = modelID
        self.vector = vector
        self.createdAt = createdAt
    }
}

public struct MemoryEmbeddingCandidate: Equatable, Sendable {
    public let observation: MemoryObservation
    public let embedding: MemoryObservationEmbedding

    public init(
        observation: MemoryObservation,
        embedding: MemoryObservationEmbedding
    ) {
        self.observation = observation
        self.embedding = embedding
    }
}

public enum MemoryRememberStatus: String, Codable, Sendable {
    case indexed
    case indexedUnlabeled
    case skippedHardIgnore
    case skippedNoMemorySignal
    case ignoredEmpty
}

public struct MemoryRememberResult: Equatable, Sendable {
    public let status: MemoryRememberStatus
    public let turn: MemoryConversationTurn?
    public let gate: MemoryGateDecision?
    public let observation: MemoryObservation?

    public init(
        status: MemoryRememberStatus,
        turn: MemoryConversationTurn?,
        gate: MemoryGateDecision?,
        observation: MemoryObservation?
    ) {
        self.status = status
        self.turn = turn
        self.gate = gate
        self.observation = observation
    }

    public static let ignoredEmpty = MemoryRememberResult(
        status: .ignoredEmpty,
        turn: nil,
        gate: nil,
        observation: nil
    )
}

public struct MemorySearchRequest: Equatable, Sendable {
    public let scope: MemoryScope
    public let query: String
    public let topK: Int
    public let minimumSimilarity: Float
    public let excludedObservationIDs: Set<String>
    public let excludedTurnIDs: Set<String>
    public let excludedSessionIDs: Set<String>

    public init(
        scope: MemoryScope,
        query: String,
        topK: Int = SLMConfiguration.production.memory.recallLimit,
        minimumSimilarity: Float = SLMConfiguration.production.memory
            .minimumSimilarity,
        excludedObservationIDs: Set<String> = [],
        excludedTurnIDs: Set<String> = [],
        excludedSessionIDs: Set<String> = []
    ) {
        self.scope = scope
        self.query = query
        self.topK = topK
        self.minimumSimilarity = minimumSimilarity
        self.excludedObservationIDs = excludedObservationIDs
        self.excludedTurnIDs = excludedTurnIDs
        self.excludedSessionIDs = excludedSessionIDs
    }
}

public struct RetrievedMemoryObservation: Equatable, Sendable {
    public let observation: MemoryObservation
    public let score: Float
    public let rank: Int

    public init(
        observation: MemoryObservation,
        score: Float,
        rank: Int
    ) {
        self.observation = observation
        self.score = score
        self.rank = rank
    }
}
