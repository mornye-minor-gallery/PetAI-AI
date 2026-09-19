#if RESOURCE_BENCH
import Foundation

// These DTO names intentionally match the on-disk contract exactly.
public struct BenchConfig: Codable, Sendable {
    public var schema_version: Int
    public var target: String
    public var profile: String
    public var scenario: String
    public var power_window_ms: Int
    public var reply_gap_ms: Int
    public var brightness: Double
    public var required_initial_thermal_state: String
    public var ram_sample_period_ms: Int
    public var recorder_pre_roll_ms: Int
    public var recorder_post_roll_ms: Int
    public var turn_timeout_ms: Int
    public var prepare_timeout_ms: Int
}
public struct BenchGeneration: Codable, Sendable {
    public var context_tokens: Int
    public var max_output_tokens: Int
    public var temperature: Float
    public var top_k: Int
    public var top_p: Float
    public var thinking_enabled: Bool
    public var conversation_mode: String
}
public struct BenchInput: Codable, Sendable {
    public var id: String
    public var system_prompt: String
    public var user_prompt: String
}
public struct BenchModel: Codable, Sendable {
    public var path: String
    public var sha256: String
}
public struct BenchPlan: Codable, Sendable {
    public var schema_version: Int
    public var run_id: UUID
    public var owner_id: UUID
    public var role: String
    public var config: BenchConfig
    public var model: BenchModel
    public var generation: BenchGeneration
    public var inputs: [BenchInput]
    public func validate() throws {
        guard schema_version == 1, config.schema_version == 1,
              config.target == "inference", config.profile == "basic",
              ["idle", "work"].contains(role), ["paced", "sustained"].contains(config.scenario),
              config.power_window_ms > 0, config.reply_gap_ms >= 0,
              config.ram_sample_period_ms > 0, config.recorder_pre_roll_ms > 0,
              config.recorder_post_roll_ms > 0, config.turn_timeout_ms > 0,
              config.prepare_timeout_ms > 0, (0...1).contains(config.brightness),
              generation.context_tokens > generation.max_output_tokens, generation.max_output_tokens > 0,
              generation.top_k > 0, (0...1).contains(generation.top_p), generation.temperature >= 0,
              generation.temperature.isFinite, generation.conversation_mode == "fresh_per_input",
              model.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !inputs.isEmpty, Set(inputs.map(\.id)).count == inputs.count,
              inputs.allSatisfy({ !$0.id.isEmpty && !$0.user_prompt.isEmpty })
        else { throw BenchFailure.invalid("invalid_or_unsupported_manifest") }
    }
}

@MainActor public protocol BenchWorkload: AnyObject {
    func prepare(plan: BenchPlan, modelURL: URL) async throws
    func perform(_ input: BenchInput, generation: BenchGeneration) async throws -> String
    func cancel() async
}
#endif
