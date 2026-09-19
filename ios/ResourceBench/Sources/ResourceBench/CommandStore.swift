#if RESOURCE_BENCH
import Foundation

/// Owned by the coordinator's serial executor; never used from the model worker.
public final class CommandStore {
    public let root: URL
    public private(set) var state: BenchState
    public init(root: URL, runID: UUID, ownerID: UUID) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: file.path) {
            state = try BenchJSON.decoder.decode(BenchState.self, from: Data(contentsOf: file))
            guard state.runID == runID, state.ownerID == ownerID, state.schemaVersion == 1 else {
                throw BenchFailure.invalid("run_ownership_conflict")
            }
            if !state.phase.terminal {
                state.phase = .failed; state.error = "interrupted"; state.revision += 1
                let receipts = root.appendingPathComponent("receipts")
                if FileManager.default.fileExists(atPath: receipts.path) {
                    for file in try FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil)
                        where file.pathExtension == "json" {
                        var receipt = try BenchJSON.decoder.decode(BenchReceipt.self, from: Data(contentsOf: file))
                        if receipt.status == "accepted" {
                            receipt.status = "failed"; receipt.error = "interrupted"
                            try BenchIO.atomic(receipt, to: file)
                        }
                    }
                }
            }
            // A restart reconciles evidence only. It cannot acquire execution rights.
            try save()
        } else {
            state = BenchState(runID: runID, ownerID: ownerID)
            try save()
        }
    }
    private func save() throws {
        state.lastMonotonicNS = String(BenchIO.nanoseconds())
        try BenchIO.atomic(state, to: root.appendingPathComponent("state.json"))
    }
    private func receiptURL(_ id: UUID) -> URL {
        root.appendingPathComponent("receipts/\(id.uuidString.lowercased()).json")
    }
    public func accept(_ command: BenchCommand, digest: String) throws -> Bool {
        guard command.runID == state.runID, command.ownerID == state.ownerID else {
            throw BenchFailure.invalid("run_ownership_conflict")
        }
        let url = receiptURL(command.operationID)
        if FileManager.default.fileExists(atPath: url.path) {
            let receipt = try BenchJSON.decoder.decode(BenchReceipt.self, from: Data(contentsOf: url))
            guard receipt.digest == digest else { throw BenchFailure.invalid("operation_conflict") }
            return false
        }
        guard command.expectedRevision == state.revision else { throw BenchFailure.invalid("state_conflict") }
        let valid: Bool
        switch command.operation {
        case "prepare": valid = state.phase == .bootReady
        case "begin": valid = state.phase == .ready
        case "cancel": valid = true
        case "snapshot": valid = false // No snapshot capability is advertised until its adapter exists.
        default: valid = false
        }
        guard valid else { throw BenchFailure.invalid("operation_not_allowed") }
        try BenchIO.atomic(BenchReceipt(digest: digest, status: "accepted"), to: url)
        return true
    }
    public func finish(_ command: BenchCommand, error: String? = nil) throws {
        let url = receiptURL(command.operationID)
        var receipt = try BenchJSON.decoder.decode(BenchReceipt.self, from: Data(contentsOf: url))
        receipt.status = error == nil ? "completed" : "failed"; receipt.error = error
        try BenchIO.atomic(receipt, to: url)
    }
    public func transition(to next: BenchPhase, error: String? = nil) throws {
        if next == state.phase { return }
        let allowed: [BenchPhase: Set<BenchPhase>] = [
            .booting: [.bootReady, .failed, .cancelled],
            .bootReady: [.preparing, .failed, .cancelled], .preparing: [.ready, .failed, .cancelled],
            .ready: [.running, .failed, .cancelled], .running: [.draining, .failed, .cancelled],
            .draining: [.finished, .failed, .cancelled]]
        guard allowed[state.phase, default: []].contains(next) else { throw BenchFailure.invalid("illegal_state_transition") }
        state.phase = next; state.error = error; state.revision += 1
        try save()
    }
    public func heartbeat() throws { state.heartbeatSeq += 1; try save() }
    public func completedTurn() throws {
        state.completedTurns += 1; state.progressSeq += 1; try save()
    }
}
#endif
