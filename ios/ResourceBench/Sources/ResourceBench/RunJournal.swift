#if RESOURCE_BENCH
import Foundation
import Darwin

/// All buffers, counters and sealing are protected by lock, including timer writes.
public final class RunJournal: @unchecked Sendable {
    private let lock = NSLock()
    public let root: URL
    private let runID: UUID
    private let processID: UUID
    private var eventSeq = 0
    private var sampleSeq = 0
    private var part = 0
    private var events: [Data] = []
    private var samples: [Data] = []
    private var files: [[String: Any]] = []
    public init(root: URL, runID: UUID, processID: UUID) throws {
        self.root = root; self.runID = runID; self.processID = processID
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
    }
    private func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
    }
    public func sample(bytes: UInt64?, boundary: String? = nil, turnID: String? = nil,
                       error: String? = nil) throws {
        try lock.withLock {
            guard samples.count < 1024 else { throw BenchFailure.invalid("ram_buffer_overflow") }
            var row: [String: Any] = ["seq": sampleSeq, "monotonic_ns": String(BenchIO.nanoseconds()),
                                      "status": error == nil ? "ok" : "error"]
            row["bytes"] = bytes.map { $0 as Any } ?? NSNull()
            row["boundary"] = boundary; row["turn_id"] = turnID; row["error"] = error
            samples.append(try encode(row)); sampleSeq += 1
        }
    }
    public func event(_ kind: String, payload: [String: Any] = [:]) throws {
        try lock.withLock {
            guard events.count < 1024 else { throw BenchFailure.invalid("event_buffer_overflow") }
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            var details = payload
            details["timebase_numer"] = timebase.numer; details["timebase_denom"] = timebase.denom
            let row: [String: Any] = ["schema_version": 1, "run_id": runID.uuidString.lowercased(),
                "process_instance_id": processID.uuidString.lowercased(), "seq": eventSeq,
                "kind": kind, "monotonic_ticks": String(mach_continuous_time()),
                "monotonic_ns": String(BenchIO.nanoseconds()), "payload": details]
            events.append(try encode(row)); eventSeq += 1
        }
    }
    public func seal(complete: Bool) throws {
        try lock.withLock {
            for (kind, rows) in [("ram", samples), ("events", events)] where !rows.isEmpty {
                let path = String(format: "raw/%06d-%@.jsonl", part, kind)
                let data = rows.reduce(into: Data()) { $0.append($1) }
                let url = root.appendingPathComponent(path)
                guard !FileManager.default.fileExists(atPath: url.path) else { throw BenchFailure.invalid("sealed_file_exists") }
                try BenchIO.atomicData(data, to: url)
                files.append(["path": path, "kind": kind, "bytes": data.count,
                              "sha256": BenchIO.digest(data), "complete": true])
                part += 1
            }
            let index: [String: Any] = ["schema_version": 1, "run_id": runID.uuidString.lowercased(),
                                       "complete": complete, "files": files]
            try BenchIO.atomicData(JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]),
                                   to: root.appendingPathComponent("artifacts.json"))
            samples.removeAll(keepingCapacity: true); events.removeAll(keepingCapacity: true)
        }
    }
}
#endif
