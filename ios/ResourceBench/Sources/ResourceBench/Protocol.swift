#if RESOURCE_BENCH
import Foundation

public enum BenchFailure: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let text): return text } }
}

nonisolated public enum BenchJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    public static var decoder: JSONDecoder { JSONDecoder() }
}

public struct BenchCommand: Codable, Sendable {
    public var schemaVersion = 1
    public var runID: UUID
    public var operationID: UUID
    public var ownerID: UUID
    public var expectedRevision: Int
    public var operation: String
    public var payload: Payload
    public struct Payload: Codable, Sendable {
        public var manifestSHA256: String
        enum CodingKeys: String, CodingKey { case manifestSHA256 = "manifest_sha256" }
    }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", runID = "run_id", operationID = "operation_id"
        case ownerID = "owner_id", expectedRevision = "expected_revision", operation, payload
    }
    public init(runID: UUID, operationID: UUID, ownerID: UUID, expectedRevision: Int,
                operation: String, manifestSHA256: String) {
        self.runID = runID; self.operationID = operationID; self.ownerID = ownerID
        self.expectedRevision = expectedRevision; self.operation = operation
        self.payload = Payload(manifestSHA256: manifestSHA256)
    }
    public static func decode(name: String, data: Data) throws -> BenchCommand {
        let command = try BenchJSON.decoder.decode(Self.self, from: data)
        let expected = "\(command.operationID.uuidString.lowercased()).\(BenchIO.digest(data)).json"
        guard name == expected, command.schemaVersion == 1, command.expectedRevision >= 0,
              ["prepare", "begin", "cancel", "snapshot"].contains(command.operation),
              command.payload.manifestSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        else { throw BenchFailure.invalid("invalid_or_incomplete_command") }
        return command
    }
}

public enum BenchPhase: String, Codable, Sendable {
    case booting, bootReady = "boot_ready", preparing, ready, running, draining, finished, failed, cancelled
    public var terminal: Bool { [.finished, .failed, .cancelled].contains(self) }
}

public struct BenchState: Codable, Sendable {
    public var schemaVersion = 1
    public var runID: UUID
    public var ownerID: UUID
    public var processInstanceID = UUID()
    public var pid = ProcessInfo.processInfo.processIdentifier
    public var buildID = Bundle.main.object(forInfoDictionaryKey: "ResourceBenchBuildID") as? String
    public var bundleID = Bundle.main.bundleIdentifier
    public var phase = BenchPhase.booting
    public var revision = 0
    public var heartbeatSeq = 0
    public var progressSeq = 0
    public var completedTurns = 0
    public var error: String?
    public var lastMonotonicNS = "0"
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", runID = "run_id", ownerID = "owner_id"
        case processInstanceID = "process_instance_id", pid, phase, revision
        case buildID = "build_id", bundleID = "bundle_id"
        case heartbeatSeq = "heartbeat_seq", progressSeq = "progress_seq"
        case completedTurns = "completed_turns", error, lastMonotonicNS = "last_monotonic_ns"
    }
}

public struct BenchReceipt: Codable, Sendable {
    public var digest: String
    public var status: String
    public var error: String?
}
#endif
