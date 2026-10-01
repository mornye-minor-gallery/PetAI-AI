#if RESOURCE_BENCH
import Foundation

/// Diagnostic capture of the real Unity process. No model, prompt, or session ownership.
/// The independent flush queue preserves partial runs even when the main actor is in native code.
public final class UnityDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "resource-benchmark.checkpoint")
    private let root: URL
    private let runID: UUID
    private let instanceID = UUID()
    private let journal: RunJournal
    private let sampler: ResourceSampler
    private let samplePeriodMS: Int
    private var timer: DispatchSourceTimer?
    private var heartbeat = 0
    private var completedTurns = 0
    private let plannedTurns: Int
    private var phase = "recording"
    private var lastStage = "capture.begin"
    private var failure: String?
    public var error: String? { lock.withLock { failure } }

    public init(root: URL, runID: UUID, samplePeriodMS: Int, plannedTurns: Int = 0) throws {
        guard (10...10_000).contains(samplePeriodMS) else { throw BenchFailure.invalid("invalid_sample_period") }
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path) else {
            throw BenchFailure.invalid("diagnostic_run_already_started")
        }
        self.root = root; self.runID = runID; self.samplePeriodMS = samplePeriodMS; self.plannedTurns = plannedTurns
        journal = try RunJournal(root: root, runID: runID, processID: instanceID)
        sampler = ResourceSampler(journal: journal)
        try stage("capture.begin", fields: ["target": "unity", "profile": "unity-memory",
            "memory_metric": "phys_footprint", "power_measured": false,
            "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"])
    }

    public func start(flushPeriodMS: Int = 500) throws {
        try lock.withLock {
            guard timer == nil, phase == "recording", flushPeriodMS > 0 else {
                throw BenchFailure.invalid("capture_already_started_or_finished")
            }
            try sampler.start(periodMS: samplePeriodMS)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(flushPeriodMS), repeating: .milliseconds(flushPeriodMS))
            timer.setEventHandler { [weak self] in self?.checkpoint() }
            self.timer = timer; timer.resume()
        }
    }

    public func stage(_ name: String, fields: [String: Any] = [:]) throws {
        try lock.withLock {
            guard phase == "recording" else { throw BenchFailure.invalid("capture_finished") }
            lastStage = name
            if name == "turn_end" { completedTurns += 1 }
            try sampler.boundary(name, turnID: fields["turn_id"] as? String)
            try journal.event(name, payload: fields)
            // Do not postpone the only evidence before a potentially fatal native call.
            try journal.seal(complete: false)
            try saveState()
        }
    }

    private func checkpoint() {
        lock.withLock {
            guard phase == "recording" else { return }
            do {
                if let error = sampler.lastError { throw BenchFailure.invalid(error) }
                heartbeat += 1
                try journal.seal(complete: false)
                try saveState()
            } catch {
                failure = String(describing: error); phase = "recording_failed"
                sampler.stop(); timer?.cancel(); timer = nil
                NSLog("ResourceBench checkpoint failed: %@", String(describing: error))
                // A failed write cannot be relabeled complete. Keep prior checkpoint intact.
            }
        }
    }

    public func finish(error: String?) throws {
        try lock.withLock {
            guard phase == "recording" else {
                if let failure { throw BenchFailure.invalid(failure) }
                return
            }
            sampler.stop(); timer?.cancel(); timer = nil
            failure = error ?? sampler.lastError
            phase = failure == nil ? "finished" : "failed"
            try journal.event("capture.end", payload: ["error": failure ?? ""])
            try journal.seal(complete: failure == nil)
            try saveState()
        }
    }

    private func saveState() throws {
        let value: [String: Any] = ["schema_version": 1, "run_id": runID.uuidString.lowercased(),
            "process_instance_id": instanceID.uuidString.lowercased(), "pid": ProcessInfo.processInfo.processIdentifier,
            "heartbeat_seq": heartbeat, "phase": phase, "last_stage": lastStage,
            "completed_turns": completedTurns, "planned_turns": plannedTurns,
            "error": failure as Any? ?? NSNull(), "target": "unity", "profile": "unity-memory"]
        try BenchIO.atomicData(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                               to: root.appendingPathComponent("state.json"))
    }
    deinit { timer?.cancel(); sampler.stop() }
}
#endif
