import Foundation

/// Calculation is complete; the store assigns the sequence and persists this as one unit.
public struct MemoryPreparedWrite: Sendable {
    public let request: MemoryWriteRequest
    public let decision: MemoryGateDecision
    public let gateResultID: String
    public let observationID: String
    public let embedding: MemoryObservationEmbedding?
    public let createdAt: Date

    public init(request: MemoryWriteRequest, decision: MemoryGateDecision,
                gateResultID: String, observationID: String,
                embedding: MemoryObservationEmbedding?, createdAt: Date) {
        self.request = request
        self.decision = decision
        self.gateResultID = gateResultID
        self.observationID = observationID
        self.embedding = embedding
        self.createdAt = createdAt
    }

    func result(for turn: MemoryConversationTurn) -> MemoryRememberResult {
        if decision.regex.hardIgnore {
            return MemoryRememberResult(status: .skippedHardIgnore, turn: turn,
                                        gate: decision, observation: nil)
        }
        if decision.observationLabels.isEmpty {
            return MemoryRememberResult(status: .skippedNoMemorySignal, turn: turn,
                                        gate: decision, observation: nil)
        }
        let observation = MemoryObservation(
            id: observationID, turnID: turn.id, sessionID: turn.sessionID,
            sequence: turn.sequence, scope: turn.scope, occurredAt: turn.occurredAt,
            rawText: turn.rawText,
            labelEvidence: decision.observationLabels.map(decision.evidence(for:)),
            createdAt: createdAt)
        return MemoryRememberResult(status: .indexed, turn: turn,
                                    gate: decision, observation: observation)
    }
}
