#if RESOURCE_BENCH
import Foundation

public struct UnityDiagnosticPlan: Codable, Sendable {
    public struct Input: Codable, Sendable {
        public let id: String
        public let prompt: String
    }
    public let schema_version: Int
    public let run_id: String
    public let character_id: String
    public let player_name: String
    public let thinking_enabled: Bool
    public let ram_sample_period_ms: Int
    public let reply_gap_ms: Int
    public let timeout_ms: Int
    public let inputs: [Input]

    public func validate() throws {
        guard schema_version == 1, let id = UUID(uuidString: run_id), id.uuidString.lowercased() == run_id,
              !character_id.isEmpty, !player_name.isEmpty,
              (10...10_000).contains(ram_sample_period_ms), (0...60_000).contains(reply_gap_ms),
              (1_000...3_600_000).contains(timeout_ms), !inputs.isEmpty, inputs.count <= 100,
              Set(inputs.map(\.id)).count == inputs.count,
              inputs.allSatisfy({ !$0.id.isEmpty && !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw BenchFailure.invalid("invalid_unity_diagnostic_plan") }
    }
}
#endif
