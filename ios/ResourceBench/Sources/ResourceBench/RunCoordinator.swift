#if RESOURCE_BENCH
import Foundation
import OSLog

/// Coordinates work, but the native runtime and RAM timer have separate executors.
@MainActor public final class RunCoordinator {
    public let store: CommandStore
    public let journal: RunJournal
    public let sampler: ResourceSampler
    public let plan: BenchPlan
    private let manifestHash: String
    private let modelURL: URL
    private let workload: any BenchWorkload
    private let environment: () throws -> Void
    private let restore: () -> Void
    private let recordEnvironment: () throws -> Void
    private let initialConditions: () -> Bool
    private var polling: Task<Void, Never>?
    private var job: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var cancelled = false
    private var failure: String?
    private var lastSeal = BenchIO.nanoseconds()
    private let log = OSLog(subsystem: "org.petai.resourcebench", category: "intervals")
    private var powerID: OSSignpostID?

    public init(root: URL, modelsRoot: URL, plan: BenchPlan, manifestHash: String,
                workload: any BenchWorkload, environment: @escaping () throws -> Void,
                restore: @escaping () -> Void, recordEnvironment: @escaping () throws -> Void = {},
                initialConditions: @escaping () -> Bool = { true }) throws {
        try plan.validate()
        self.plan = plan; self.manifestHash = manifestHash; self.workload = workload
        self.environment = environment; self.restore = restore
        self.recordEnvironment = recordEnvironment; self.initialConditions = initialConditions
        modelURL = try BenchIO.safeURL(plan.model.path, under: modelsRoot)
        store = try CommandStore(root: root, runID: plan.run_id, ownerID: plan.owner_id)
        journal = try RunJournal(root: root, runID: plan.run_id, processID: store.state.processInstanceID)
        sampler = ResourceSampler(journal: journal)
    }
    public func start() throws {
        guard !store.state.phase.terminal else { restore(); return }
        try environment()
        try journal.event("boot_ready", payload: ["capabilities": ["basic", "inference", "protocol_v1"]])
        try journal.seal(complete: false)
        try store.transition(to: .bootReady)
        timeout(plan.config.prepare_timeout_ms, reason: "boot_timeout")
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                do {
                    try self?.poll()
                    try await Task.sleep(for: .milliseconds(250))
                } catch is CancellationError { return }
                catch {
                    await self?.abort(String(describing: error))
                    // A condition failure ends the experiment, not ownership observation.
                    // Terminal heartbeats let the host confirm and terminate this process.
                    if self?.store.state.phase.terminal != true { return }
                }
            }
        }
    }
    private func poll() throws {
        if store.state.phase.terminal {
            if BenchIO.nanoseconds() - lastSeal >= 5_000_000_000 {
                try store.heartbeat(); lastSeal = BenchIO.nanoseconds()
            }
        } else {
            try environment()
            if let error = sampler.lastError { throw BenchFailure.invalid(error) }
            if BenchIO.nanoseconds() - lastSeal >= 5_000_000_000 {
                try journal.seal(complete: false); try store.heartbeat(); lastSeal = BenchIO.nanoseconds()
            }
        }
        let directory = store.root.appendingPathComponent("commands")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            where file.pathExtension == "json" {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw BenchFailure.invalid("symbolic_command")
            }
            let data = try Data(contentsOf: file)
            // Copy is not atomic on the device. A partial command is never accepted.
            // Host timeout owns the transfer failure; a complete bad command is rejected.
            let parts = file.lastPathComponent.split(separator: ".")
            guard parts.count == 3, String(parts[1]) == BenchIO.digest(data) else { continue }
            let rejection = store.root.appendingPathComponent("rejections/" + file.lastPathComponent)
            if FileManager.default.fileExists(atPath: rejection.path) { continue }
            do {
                let command = try BenchCommand.decode(name: file.lastPathComponent, data: data)
                try submit(command, digest: BenchIO.digest(data))
            } catch let error as BenchFailure {
                try BenchIO.atomic(BenchReceipt(digest: BenchIO.digest(data), status: "rejected",
                                               error: String(describing: error)), to: rejection)
            } catch let error as DecodingError {
                try BenchIO.atomic(BenchReceipt(digest: BenchIO.digest(data), status: "rejected",
                                               error: String(describing: error)), to: rejection)
            }
        }
    }
    public func submit(_ command: BenchCommand, digest: String) throws {
        guard command.payload.manifestSHA256 == manifestHash else { throw BenchFailure.invalid("manifest_hash_mismatch") }
        guard try store.accept(command, digest: digest) else { return }
        if command.operation == "cancel" {
            Task { [weak self] in
                guard let self else { return }
                await self.abort(nil)
                await self.job?.value
                do { try self.store.finish(command) }
                catch { self.persistFatal(error) }
            }
            return
        }
        // Reserve the phase synchronously before spawning work: a second command
        // must not acquire the same ready/boot phase during the next executor turn.
        try store.transition(to: command.operation == "prepare" ? .preparing : .running)
        job = Task { [weak self] in
            guard let self else { return }
            do {
                if command.operation == "prepare" { try await self.prepare() }
                else { try await self.run() }
                try self.store.finish(command)
            } catch {
                if self.failure == nil && !self.cancelled { self.failure = String(describing: error) }
                do { try self.store.finish(command, error: self.failure ?? "cancelled") }
                catch { self.persistFatal(error) }
                await self.finishFailure()
            }
        }
    }
    private func timeout(_ milliseconds: Int, reason: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
            await self?.abort(reason)
        }
    }
    private func check() throws {
        try Task.checkCancellation()
        if let failure { throw BenchFailure.invalid(failure) }
        guard !cancelled else { throw CancellationError() }
        try environment()
    }
    private func prepare() async throws {
        try store.transition(to: .preparing)
        timeout(plan.config.prepare_timeout_ms, reason: "prepare_timeout")
        // Hashing precedes the measured model-load boundary and runs off the main actor.
        let url = modelURL
        let hash = try await Task.detached { try BenchIO.digestFile(url) }.value
        guard hash == plan.model.sha256 else { throw BenchFailure.invalid("model_hash_mismatch") }
        try check()
        try sampler.start(periodMS: plan.config.ram_sample_period_ms)
        try sampler.boundary("model_before")
        try journal.event("model_load_start")
        try await workload.prepare(plan: plan, modelURL: modelURL)
        try check()
        try sampler.boundary("model_after")
        try journal.event("model_load_end")
        try journal.seal(complete: false)
        while !initialConditions() {
            try check(); try await Task.sleep(for: .seconds(1))
        }
        try store.transition(to: .ready)
        timeout(plan.config.prepare_timeout_ms, reason: "begin_timeout")
    }
    private func markWindow(begin: Bool) throws {
        try recordEnvironment()
        let before = BenchIO.nanoseconds()
        if begin {
            let id = OSSignpostID(log: log); powerID = id
            os_signpost(.begin, log: log, name: "PowerWindow", signpostID: id,
                        "%{public}@", plan.run_id.uuidString.lowercased() as NSString)
        } else if let id = powerID {
            os_signpost(.end, log: log, name: "PowerWindow", signpostID: id,
                        "%{public}@", plan.run_id.uuidString.lowercased() as NSString)
            powerID = nil
        }
        try journal.event(begin ? "window_start" : "window_end",
                          payload: ["signpost_before_ns": String(before), "signpost_after_ns": String(BenchIO.nanoseconds())])
    }
    private func run() async throws {
        watchdog?.cancel()
        try check()
        guard initialConditions() else { throw BenchFailure.invalid("initial_conditions_changed") }
        try store.transition(to: .running)
        let fixedTurns = plan.config.scenario == "fixed"
        if !fixedTurns {
            try await Task.sleep(for: .milliseconds(plan.config.recorder_pre_roll_ms))
        }
        try check()
        guard initialConditions() else { throw BenchFailure.invalid("initial_conditions_changed") }
        try markWindow(begin: true)
        let end = fixedTurns ? nil : BenchIO.nanoseconds() + UInt64(plan.config.power_window_ms) * 1_000_000
        let window: Task<Void, Never>? = fixedTurns ? nil : Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(self?.plan.config.power_window_ms ?? 0))
                try self?.markWindow(begin: false)
            } catch { if !(error is CancellationError) { await self?.abort(String(describing: error)) } }
        }
        defer { window?.cancel() }
        if plan.role == "idle" {
            try await Task.sleep(for: .milliseconds(plan.config.power_window_ms))
        } else {
            var index = 0
            while (fixedTurns ? index < plan.inputs.count : BenchIO.nanoseconds() < end!) {
                try check()
                guard index < plan.inputs.count else { throw BenchFailure.invalid("fixture_exhausted") }
                let input = plan.inputs[index]
                try sampler.boundary("turn_start", turnID: input.id)
                try journal.event("turn_start", payload: ["turn_id": input.id])
                timeout(plan.config.turn_timeout_ms, reason: "turn_timeout")
                let output = try await workload.perform(input, generation: plan.generation)
                watchdog?.cancel(); try check()
                try sampler.boundary("turn_end", turnID: input.id)
                try journal.event("turn_end", payload: ["turn_id": input.id, "output": output])
                try journal.seal(complete: false); try store.completedTurn(); index += 1
                if plan.config.scenario == "paced", BenchIO.nanoseconds() < end! {
                    let now = BenchIO.nanoseconds()
                    let remaining = now < end! ? end! - now : 0
                    try await Task.sleep(nanoseconds: min(UInt64(plan.config.reply_gap_ms) * 1_000_000, remaining))
                }
            }
            if fixedTurns { try markWindow(begin: false) }
        }
        await window?.value
        try check(); try store.transition(to: .draining)
        if !fixedTurns {
            try await Task.sleep(for: .milliseconds(plan.config.recorder_post_roll_ms))
        }
        try check(); sampler.stop()
        try journal.event("finished"); try journal.seal(complete: true)
        try store.transition(to: .finished); restore()
    }
    public func abort(_ reason: String?) async {
        guard !store.state.phase.terminal else { return }
        if let reason { failure = failure ?? reason } else { cancelled = true }
        watchdog?.cancel(); job?.cancel()
        await workload.cancel()
        // Cancellation acknowledgement is not termination. The job owns its final state.
        if job == nil || store.state.phase == .ready || [.booting, .bootReady].contains(store.state.phase) {
            await finishFailure()
        }
    }
    private func finishFailure() async {
        guard !store.state.phase.terminal else { return }
        sampler.stop(); watchdog?.cancel()
        do {
            try journal.event("aborted", payload: ["reason": failure ?? "cancelled"])
            try journal.seal(complete: false)
            try store.transition(to: failure == nil ? .cancelled : .failed, error: failure ?? "cancelled")
        } catch { persistFatal(error) }
        restore()
    }
    private func persistFatal(_ error: Error) {
        // Disk failure cannot be represented as a successful checkpoint.
        // The previous nonterminal state remains authoritative to the host.
        NSLog("ResourceBench durable recording failed: %@", String(describing: error))
        sampler.stop(); polling?.cancel(); job?.cancel(); watchdog?.cancel()
        Task { await workload.cancel() }
        restore()
    }
}
#endif
