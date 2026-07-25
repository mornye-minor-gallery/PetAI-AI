import Foundation

public enum MemoryLabel: String, Codable, CaseIterable, Sendable {
    case preference
    case event
}

public enum MemoryObservationState: String, Codable, Sendable {
    case active
    case deleted
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
    public let supersedesObservationID: String?

    public init(
        sourceMessageID: String,
        sessionID: String,
        scope: MemoryScope,
        rawText: String,
        occurredAt: Date = Date(),
        supersedesObservationID: String? = nil
    ) {
        self.sourceMessageID = sourceMessageID
        self.sessionID = sessionID
        self.scope = scope
        self.rawText = rawText
        self.occurredAt = occurredAt
        self.supersedesObservationID = supersedesObservationID
    }
}

public struct MemoryObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sourceMessageID: String
    public let sessionID: String
    public let scope: MemoryScope
    public let occurredAt: Date
    public let rawText: String
    public let labels: [MemoryLabel]
    public let classifierVersion: String
    public let state: MemoryObservationState
    public let validFrom: Date?
    public let validUntil: Date?
    public let supersedesObservationID: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: String,
        sourceMessageID: String,
        sessionID: String,
        scope: MemoryScope,
        occurredAt: Date,
        rawText: String,
        labels: some Sequence<MemoryLabel>,
        classifierVersion: String,
        state: MemoryObservationState = .active,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        supersedesObservationID: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.sourceMessageID = sourceMessageID
        self.sessionID = sessionID
        self.scope = scope
        self.occurredAt = occurredAt
        self.rawText = rawText
        self.labels = Array(Set(labels)).sorted { $0.rawValue < $1.rawValue }
        self.classifierVersion = classifierVersion
        self.state = state
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.supersedesObservationID = supersedesObservationID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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

public enum MemoryIgnoreReason: Equatable, Sendable {
    case emptyText
    case notPreferenceOrEvent
}

public enum MemoryRememberResult: Equatable, Sendable {
    case stored(MemoryObservation)
    case ignored(MemoryIgnoreReason)
}

public struct MemorySearchRequest: Equatable, Sendable {
    public let scope: MemoryScope
    public let query: String
    public let topK: Int
    public let excludedObservationIDs: Set<String>
    public let excludedSessionIDs: Set<String>

    public init(
        scope: MemoryScope,
        query: String,
        topK: Int = 3,
        excludedObservationIDs: Set<String> = [],
        excludedSessionIDs: Set<String> = []
    ) {
        self.scope = scope
        self.query = query
        self.topK = topK
        self.excludedObservationIDs = excludedObservationIDs
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
