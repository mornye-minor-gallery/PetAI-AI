import Foundation

public enum MemoryEngineError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case insecureStoreConfiguration
    case invalidSearchLimit
    case notPrepared
}

extension MemoryEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(field):
            "EdgeMem requires a non-empty \(field)."
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
    private let retriever: (any MemoryRetrieving)?
    private let diagnostics: any MemoryDiagnostics
    private let securityRequirement: MemoryStoreSecurityRequirement
    private let makeObservationID: @Sendable () -> String
    private let now: @Sendable () -> Date
    private var isPrepared = false

    public init(
        store: any MemoryObservationStoring,
        classifier: any MemoryObservationClassifying =
            NaivePreferenceEventClassifier(),
        retriever: (any MemoryRetrieving)? = nil,
        diagnostics: any MemoryDiagnostics = MemoryDebugDiagnostics(),
        securityRequirement: MemoryStoreSecurityRequirement =
            .encryptedOnDeviceOnly,
        makeObservationID: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased()
        },
        now: @escaping @Sendable () -> Date = {
            Date()
        }
    ) {
        self.store = store
        self.classifier = classifier
        self.retriever = retriever
        self.diagnostics = diagnostics
        self.securityRequirement = securityRequirement
        self.makeObservationID = makeObservationID
        self.now = now
    }

    public func prepare() async throws {
        guard securityRequirement.accepts(store.securityPolicy) else {
            throw MemoryEngineError.insecureStoreConfiguration
        }
        try await store.initialize()
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
            return .ignored(.emptyText)
        }

        let labels = try await classifier.classify(request.rawText)
        guard !labels.isEmpty else {
            return .ignored(.notPreferenceOrEvent)
        }

        let timestamp = now()
        let observation = MemoryObservation(
            id: makeObservationID(),
            sourceMessageID: request.sourceMessageID,
            sessionID: request.sessionID,
            scope: request.scope,
            occurredAt: request.occurredAt,
            rawText: request.rawText,
            labels: labels,
            classifierVersion: classifier.version,
            supersedesObservationID: request.supersedesObservationID,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try requirePrepared()
        try await store.save(observation)
        return .stored(observation)
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
            in: scope,
            updatedAt: now()
        )
    }

    public func close() async {
        isPrepared = false
        await store.close()
    }

    private func requirePrepared() throws {
        guard isPrepared else {
            throw MemoryEngineError.notPrepared
        }
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
