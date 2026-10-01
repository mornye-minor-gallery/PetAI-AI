#if RESOURCE_BENCH
import Foundation
import Darwin

/// Lock serializes boundary queries and the dedicated timer, not model execution.
public final class ResourceSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let journal: RunJournal
    private let queue = DispatchQueue(label: "resource-benchmark.ram")
    private var timer: DispatchSourceTimer?
    private var turnID: String?
    private var failure: String?
    public init(journal: RunJournal) { self.journal = journal }
    public static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let code = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let requiredBytes = MemoryLayout<task_vm_info_data_t>.offset(of: \task_vm_info_data_t.phys_footprint)! + MemoryLayout<UInt64>.size
        guard code == KERN_SUCCESS, Int(count) * MemoryLayout<integer_t>.size >= requiredBytes else {
            throw BenchFailure.invalid("task_info_failed:\(code):count=\(count)")
        }
        return info.phys_footprint
    }
    public var lastError: String? { lock.withLock { failure } }
    public func start(periodMS: Int) throws {
        guard periodMS > 0 else { throw BenchFailure.invalid("invalid_sample_period") }
        lock.withLock {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + .milliseconds(periodMS), repeating: .milliseconds(periodMS))
            source.setEventHandler { [weak self] in self?.periodic() }
            timer = source; source.resume()
        }
    }
    public func boundary(_ name: String, turnID: String? = nil) throws {
        try lock.withLock {
            if name == "turn_start" { self.turnID = turnID }
            try journal.sample(bytes: Self.footprint(), boundary: name, turnID: turnID)
            if name == "turn_end" { self.turnID = nil }
        }
    }
    private func periodic() {
        lock.withLock {
            guard failure == nil else { return }
            do { try journal.sample(bytes: Self.footprint(), turnID: turnID) }
            catch {
                failure = String(describing: error)
                do { try journal.sample(bytes: nil, turnID: turnID, error: failure) }
                catch { failure = "sample_and_error_record_failed:\(error)" }
            }
        }
    }
    public func stop() { lock.withLock { timer?.cancel(); timer = nil } }
    deinit { timer?.cancel() }
}
#endif
