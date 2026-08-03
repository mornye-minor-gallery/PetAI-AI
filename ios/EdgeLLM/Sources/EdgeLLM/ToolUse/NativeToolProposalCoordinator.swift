import Foundation

public enum NativeToolCoordinatorError: Error, Equatable, Sendable {
    case requestAlreadyExists
    case anotherRequestIsActive
    case requestNotFound
    case invalidTransition
    case confirmedProposalMismatch
    case requestAlreadyExecuted
}

public struct NativeToolRequestSnapshot: Equatable, Sendable {
    public let proposal: ValidatedToolProposal
    public let state: UnityToolLifecycleState
    public let hasExecuted: Bool
    public let errorCode: NativeToolErrorCode?

    public init(
        proposal: ValidatedToolProposal,
        state: UnityToolLifecycleState,
        hasExecuted: Bool,
        errorCode: NativeToolErrorCode? = nil
    ) {
        self.proposal = proposal
        self.state = state
        self.hasExecuted = hasExecuted
        self.errorCode = errorCode
    }

    public var unityEvent: UnityToolStateEvent {
        UnityToolStateEvent(
            state: state,
            requestID: proposal.requestID,
            tool: proposal.tool,
            errorCode: errorCode
        )
    }
}

public actor NativeToolProposalCoordinator {
    public typealias Executor = @Sendable (
        ValidatedToolProposal
    ) async throws -> JSONValue

    private var requests: [String: NativeToolRequestSnapshot] = [:]
    private let executor: Executor

    public init(executor: @escaping Executor) {
        self.executor = executor
    }

    @discardableResult
    public func register(
        _ proposal: ValidatedToolProposal
    ) throws -> UnityToolStateEvent {
        guard requests[proposal.requestID] == nil else {
            throw NativeToolCoordinatorError.requestAlreadyExists
        }
        guard !requests.values.contains(where: Self.isActive) else {
            throw NativeToolCoordinatorError.anotherRequestIsActive
        }
        let snapshot = NativeToolRequestSnapshot(
            proposal: proposal,
            state: .proposalReady,
            hasExecuted: false
        )
        requests[proposal.requestID] = snapshot
        return snapshot.unityEvent
    }

    @discardableResult
    public func beginConfirmation(
        requestID: String
    ) throws -> UnityToolStateEvent {
        let current = try requireRequest(requestID)
        guard current.state == .proposalReady else {
            throw NativeToolCoordinatorError.invalidTransition
        }
        let updated = NativeToolRequestSnapshot(
            proposal: current.proposal,
            state: .awaitingConfirmation,
            hasExecuted: false
        )
        requests[requestID] = updated
        return updated.unityEvent
    }

    public func approveAndExecute(
        _ confirmedProposal: ValidatedToolProposal
    ) async throws -> NativeToolExecutionEnvelope {
        let requestID = confirmedProposal.requestID
        let current = try requireRequest(requestID)
        guard !current.hasExecuted else {
            throw NativeToolCoordinatorError.requestAlreadyExecuted
        }
        guard current.state == .awaitingConfirmation else {
            throw NativeToolCoordinatorError.invalidTransition
        }
        guard current.proposal.tool == confirmedProposal.tool else {
            throw NativeToolCoordinatorError.confirmedProposalMismatch
        }

        requests[requestID] = NativeToolRequestSnapshot(
            proposal: confirmedProposal,
            state: .running,
            hasExecuted: true
        )

        do {
            let data = try await executor(confirmedProposal)
            let completed = NativeToolRequestSnapshot(
                proposal: confirmedProposal,
                state: .completed,
                hasExecuted: true
            )
            requests[requestID] = completed
            return NativeToolExecutionEnvelope(
                requestID: requestID,
                tool: confirmedProposal.tool,
                status: .success,
                data: data
            )
        } catch let code as NativeToolErrorCode {
            requests[requestID] = NativeToolRequestSnapshot(
                proposal: confirmedProposal,
                state: .failed,
                hasExecuted: true,
                errorCode: code
            )
            return NativeToolExecutionEnvelope(
                requestID: requestID,
                tool: confirmedProposal.tool,
                status: .failure,
                errorCode: code
            )
        } catch {
            requests[requestID] = NativeToolRequestSnapshot(
                proposal: confirmedProposal,
                state: .failed,
                hasExecuted: true,
                errorCode: .nativeFailure
            )
            return NativeToolExecutionEnvelope(
                requestID: requestID,
                tool: confirmedProposal.tool,
                status: .failure,
                errorCode: .nativeFailure
            )
        }
    }

    @discardableResult
    public func cancel(
        requestID: String
    ) throws -> NativeToolExecutionEnvelope {
        let current = try requireRequest(requestID)
        guard
            current.state == .proposalReady
                || current.state == .awaitingConfirmation
        else {
            throw NativeToolCoordinatorError.invalidTransition
        }
        requests[requestID] = NativeToolRequestSnapshot(
            proposal: current.proposal,
            state: .cancelled,
            hasExecuted: false,
            errorCode: .cancelledByUser
        )
        return NativeToolExecutionEnvelope(
            requestID: requestID,
            tool: current.proposal.tool,
            status: .cancelled,
            errorCode: .cancelledByUser
        )
    }

    public func snapshot(
        requestID: String
    ) -> NativeToolRequestSnapshot? {
        requests[requestID]
    }

    public func removeFinished(requestID: String) throws {
        let current = try requireRequest(requestID)
        guard !Self.isActive(current) else {
            throw NativeToolCoordinatorError.invalidTransition
        }
        requests.removeValue(forKey: requestID)
    }

    private func requireRequest(
        _ requestID: String
    ) throws -> NativeToolRequestSnapshot {
        guard let current = requests[requestID] else {
            throw NativeToolCoordinatorError.requestNotFound
        }
        return current
    }

    private static func isActive(
        _ snapshot: NativeToolRequestSnapshot
    ) -> Bool {
        switch snapshot.state {
        case .proposalReady, .awaitingConfirmation, .running:
            true
        case .completed, .cancelled, .failed:
            false
        }
    }
}
