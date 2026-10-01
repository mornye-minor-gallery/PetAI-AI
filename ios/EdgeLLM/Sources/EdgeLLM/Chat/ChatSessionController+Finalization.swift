import Foundation

struct NativeTurnDecision: Codable, Sendable {
    let requestId: String
    let cancelled: Bool
    let text: String
}

struct PendingTurnDecision {
    let requestID: String
    let text: String
    let cancelled: Bool
    let emittedText: String
    let continuation: CheckedContinuation<NativeTurnDecision?, Never>
}

extension ChatSessionController {
    // Generation can finish while its last tokens are still queued in Unity.
    // Only the display owner can decide whether the user stopped before seeing them.
    func displayDecision(_ requestID: String, text: String,
                         cancelled: Bool) async -> NativeTurnDecision? {
        guard !isUnloading, maintenanceRequestID == nil else { return nil }
        return await withCheckedContinuation { continuation in
            precondition(pendingTurnDecision == nil)
            pendingTurnDecision = PendingTurnDecision(requestID: requestID, text: text,
                cancelled: cancelled, emittedText: routedPersonaSession.chatTurns.last?.assistantMessage ?? "",
                continuation: continuation)
            emit(type: cancelled ? "cancellation_pending" : "completion_pending",
                 requestId: requestID, text: text)
        }
    }

    public func finalizeTurn(json: String) {
        guard let decision = try? JSONDecoder().decode(NativeTurnDecision.self, from: Data(json.utf8)) else {
            logger.error("Rejected malformed turn finalization")
            rejectPendingTurnDecision()
            return
        }
        // Stale and duplicate acknowledgements never claim a different request.
        guard let pending = pendingTurnDecision, pending.requestID == decision.requestId,
              activeRequestId == decision.requestId else { return }
        let valid = decision.cancelled
            ? pending.emittedText.utf8.starts(with: decision.text.utf8)
            : !pending.cancelled && decision.text == pending.text
        guard valid else {
            logger.error("Rejected inconsistent turn finalization")
            rejectPendingTurnDecision()
            return
        }
        pendingTurnDecision = nil
        // Claim the decision before resuming its writer, closing actor reentrancy.
        isCommittingTurn = true
        pending.continuation.resume(returning: decision)
    }

    func abandonPendingTurnDecision() {
        let pending = pendingTurnDecision
        pendingTurnDecision = nil
        pending?.continuation.resume(returning: nil)
    }

    private func rejectPendingTurnDecision() {
        guard let pending = pendingTurnDecision else { return }
        pendingTurnDecision = nil
        activeRequestId = nil
        cancelRequested = false
        recentTurnsLoaded = false
        state = .failed
        pending.continuation.resume(returning: nil)
        emitError(code: "chat_turn_state_failed", message: "대화 상태를 확정하지 못했습니다. 대화를 다시 준비해 주세요.",
                  requestId: pending.requestID)
    }
}
