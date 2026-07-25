import Foundation

public struct MemoryStoreSecurityPolicy: Equatable, Sendable {
    public let requiresDatabaseEncryption: Bool
    public let applicationSandboxOnly: Bool
    public let excludedFromCloudBackup: Bool

    public init(
        requiresDatabaseEncryption: Bool,
        applicationSandboxOnly: Bool,
        excludedFromCloudBackup: Bool
    ) {
        self.requiresDatabaseEncryption = requiresDatabaseEncryption
        self.applicationSandboxOnly = applicationSandboxOnly
        self.excludedFromCloudBackup = excludedFromCloudBackup
    }

    public static let encryptedOnDeviceOnly = MemoryStoreSecurityPolicy(
        requiresDatabaseEncryption: true,
        applicationSandboxOnly: true,
        excludedFromCloudBackup: true
    )

    public static let appPrivatePrototype = MemoryStoreSecurityPolicy(
        requiresDatabaseEncryption: false,
        applicationSandboxOnly: true,
        excludedFromCloudBackup: true
    )
}

public enum MemoryStoreSecurityRequirement: Equatable, Sendable {
    case encryptedOnDeviceOnly
    case allowsUnencryptedAppPrivatePrototype

    func accepts(_ policy: MemoryStoreSecurityPolicy) -> Bool {
        guard
            policy.applicationSandboxOnly,
            policy.excludedFromCloudBackup
        else {
            return false
        }

        switch self {
        case .encryptedOnDeviceOnly:
            return policy.requiresDatabaseEncryption
        case .allowsUnencryptedAppPrivatePrototype:
            return true
        }
    }
}

public protocol MemoryObservationClassifying: Sendable {
    var version: String { get }

    func evaluate(_ text: String) async throws -> MemoryGateDecision
}

public protocol MemoryObservationStoring: Sendable {
    var securityPolicy: MemoryStoreSecurityPolicy { get }

    func initialize() async throws
    func saveUserTurn(
        id: String,
        sessionID: String,
        scope: MemoryScope,
        rawText: String,
        occurredAt: Date
    ) async throws -> MemoryConversationTurn
    func saveGateResult(_ result: MemoryGateResult) async throws
    func saveObservation(
        _ observation: MemoryObservation,
        embedding: MemoryObservationEmbedding?
    ) async throws
    func activeObservations(in scope: MemoryScope) async throws
        -> [MemoryObservation]
    func markDeleted(
        observationID: String,
        in scope: MemoryScope
    ) async throws
    func close() async
}

extension MemoryObservationStoring {
    public func saveObservation(
        _ observation: MemoryObservation
    ) async throws {
        try await saveObservation(observation, embedding: nil)
    }
}

public protocol MemoryEmbeddingCandidateLoading: Sendable {
    func embeddingCandidates(
        in scope: MemoryScope,
        modelID: String
    ) async throws -> [MemoryEmbeddingCandidate]
}

public protocol MemoryRetrieving: Sendable {
    func search(_ request: MemorySearchRequest) async throws
        -> [RetrievedMemoryObservation]
}

public protocol MemoryDiagnostics: Sendable {
    func logSearchFailure(_ message: String) async
}

public struct MemoryDebugDiagnostics: MemoryDiagnostics {
    public init() {}

    public func logSearchFailure(_ message: String) async {
#if DEBUG
        print("[EdgeMem] retrieval failed: \(message)")
#endif
    }
}
