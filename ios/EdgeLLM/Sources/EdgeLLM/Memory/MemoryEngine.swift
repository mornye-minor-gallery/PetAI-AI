import Foundation

public enum MemoryEngineError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidEmbeddingDimension(expected: Int, actual: Int)
    case nonFiniteEmbedding(index: Int)
    case insecureStoreConfiguration
    case invalidSearchLimit
    case notPrepared
}

extension MemoryEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(field):
            "EdgeMem requires a non-empty \(field)."
        case let .invalidEmbeddingDimension(expected, actual):
            "EdgeMem expected a \(expected)-value embedding, but received \(actual)."
        case let .nonFiniteEmbedding(index):
            "EdgeMem embedding contains a non-finite value at index \(index)."
        case .insecureStoreConfiguration:
            "The EdgeMem store does not satisfy the selected security requirement."
        case .invalidSearchLimit:
            "EdgeMem search topK must be greater than zero."
        case .notPrepared:
            "EdgeMem must be prepared before accessing its store."
        }
    }
}

public actor MemoryEngine {
    private let store: any MemoryObservationStoring
    private let classifier: any MemoryObservationClassifying
    private let embedder: (any TextEmbeddingProviding)?
    private let retriever: (any MemoryRetrieving)?
    private let diagnostics: any MemoryDiagnostics
    private let securityRequirement: MemoryStoreSecurityRequirement
    private let makeObservationID: @Sendable () -> String
    private let makeGateResultID: @Sendable () -> String
    private let now: @Sendable () -> Date
    private var isPrepared = false
    private var lifecycleGeneration: UInt = 0

    public init(
        store: any MemoryObservationStoring,
        classifier: any MemoryObservationClassifying,
        embedder: (any TextEmbeddingProviding)? = nil,
        retriever: (any MemoryRetrieving)? = nil,
        diagnostics: any MemoryDiagnostics = MemoryDebugDiagnostics(),
        securityRequirement: MemoryStoreSecurityRequirement =
            .encryptedOnDeviceOnly,
        makeObservationID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        },
        makeGateResultID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        },
        now: @escaping @Sendable () -> Date = {
            Date()
        }
    ) {
        self.store = store
        self.classifier = classifier
        self.embedder = embedder
        self.retriever = retriever
        self.diagnostics = diagnostics
        self.securityRequirement = securityRequirement
        self.makeObservationID = makeObservationID
        self.makeGateResultID = makeGateResultID
        self.now = now
    }

    public func prepare() async throws {
        guard securityRequirement.accepts(store.securityPolicy) else {
            throw MemoryEngineError.insecureStoreConfiguration
        }
        let generation = lifecycleGeneration
        try await store.initialize()
        guard generation == lifecycleGeneration else {
            throw MemoryEngineError.notPrepared
        }
        isPrepared = true
    }

    public func remember(
        _ request: MemoryWriteRequest
    ) async throws -> MemoryRememberResult {
        try requirePrepared()
        try Self.validateIdentifier(
            request.sourceMessageID,
            field: "sourceMessageID"
        )
        try Self.validateIdentifier(request.sessionID, field: "sessionID")
        try Self.validateIdentifier(request.scope.userID, field: "userID")
        try Self.validateIdentifier(
            request.scope.characterID,
            field: "characterID"
        )

        let trimmedText = request.rawText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedText.isEmpty else {
            return .ignoredEmpty
        }

        let turn = try await store.saveUserTurn(
            id: request.sourceMessageID,
            sessionID: request.sessionID,
            scope: request.scope,
            rawText: request.rawText,
            occurredAt: request.occurredAt
        )
        let decision = try await classifier.evaluate(request.rawText)
        let timestamp = now()
        try requirePrepared()
        try await store.saveGateResult(
            MemoryGateResult(
                id: makeGateResultID(),
                turnID: turn.id,
                decision: decision,
                createdAt: timestamp
            )
        )

        guard !decision.regex.hardIgnore else {
            return MemoryRememberResult(
                status: .skippedHardIgnore,
                turn: turn,
                gate: decision,
                observation: nil
            )
        }

        guard !decision.observationLabels.isEmpty else {
            return MemoryRememberResult(
                status: .skippedNoMemorySignal,
                turn: turn,
                gate: decision,
                observation: nil
            )
        }

        let observation = MemoryObservation(
            id: makeObservationID(),
            turnID: turn.id,
            sessionID: turn.sessionID,
            sequence: turn.sequence,
            scope: turn.scope,
            occurredAt: turn.occurredAt,
            rawText: turn.rawText,
            labelEvidence: decision.observationLabels.map(
                decision.evidence(for:)
            ),
            createdAt: timestamp
        )
        let embedding = try await makeEmbedding(
            for: observation,
            text: trimmedText,
            createdAt: timestamp
        )
        try requirePrepared()
        try await store.saveObservation(
            observation,
            embedding: embedding
        )
        return MemoryRememberResult(
            status: observation.labels.isEmpty
                ? .indexedUnlabeled
                : .indexed,
            turn: turn,
            gate: decision,
            observation: observation
        )
    }

    public func recall(
        _ request: MemorySearchRequest
    ) async -> [RetrievedMemoryObservation] {
        guard request.topK > 0 else {
            await diagnostics.logSearchFailure(
                MemoryEngineError.invalidSearchLimit.localizedDescription
            )
            return []
        }

        guard let retriever else {
            await diagnostics.logSearchFailure(
                "memory retriever is not configured"
            )
            return []
        }

        do {
            return try await retriever.search(request)
        } catch {
            await diagnostics.logSearchFailure(error.localizedDescription)
            return []
        }
    }

    public func activeObservations(
        in scope: MemoryScope
    ) async throws -> [MemoryObservation] {
        try requirePrepared()
        return try await store.activeObservations(in: scope)
    }

    public func deleteObservation(
        observationID: String,
        in scope: MemoryScope
    ) async throws {
        try requirePrepared()
        try Self.validateIdentifier(
            observationID,
            field: "observationID"
        )
        try Self.validateIdentifier(scope.userID, field: "userID")
        try Self.validateIdentifier(scope.characterID, field: "characterID")
        try await store.markDeleted(
            observationID: observationID,
            in: scope
        )
    }

    public func close() async {
        lifecycleGeneration &+= 1
        isPrepared = false
        await store.close()
    }

    private func requirePrepared() throws {
        guard isPrepared else {
            throw MemoryEngineError.notPrepared
        }
    }

    private func makeEmbedding(
        for observation: MemoryObservation,
        text: String,
        createdAt: Date
    ) async throws -> MemoryObservationEmbedding? {
        guard let embedder else {
            return nil
        }
        try Self.validateIdentifier(embedder.modelID, field: "embedding modelID")
        let vector = try await embedder.embedDocument(text)
        guard vector.count == embedder.dimension else {
            throw MemoryEngineError.invalidEmbeddingDimension(
                expected: embedder.dimension,
                actual: vector.count
            )
        }
        if let index = vector.firstIndex(where: { !$0.isFinite }) {
            throw MemoryEngineError.nonFiniteEmbedding(index: index)
        }
        return MemoryObservationEmbedding(
            observationID: observation.id,
            modelID: embedder.modelID,
            vector: vector,
            createdAt: createdAt
        )
    }

    private static func validateIdentifier(
        _ value: String,
        field: String
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MemoryEngineError.invalidIdentifier(field: field)
        }
    }
}
