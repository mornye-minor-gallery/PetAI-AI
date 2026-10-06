import EdgeLLM
import Foundation

/// Only measurements cross this channel; memory selection stays in the shared Swift composer.
actor NativeTokenMeasurer: DialogueTokenMeasuring {
    nonisolated let identifier: String
    private let requestID: String
    private let thinking: Bool
    private let outputTokens: Int
    private var sequence = 0

    init(identifier: String, requestID: String, thinking: Bool, outputTokens: Int) {
        self.identifier = identifier
        self.requestID = requestID
        self.thinking = thinking
        self.outputTokens = outputTokens
    }

    func countTokens(_ text: String) throws -> Int {
        try ask(["measurement": "count_tokens", "text": text])
    }

    func measureInput(_ input: DialogueModelInput) throws -> Int {
        let generation = SLMConfiguration.production.generation
        return try ask(["measurement": "measure_input",
                 "input": try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)),
                 "sampling": ["thinking": thinking, "max_output_tokens": outputTokens,
                              "temperature": generation.responseSampling.temperature,
                              "top_k": generation.responseSampling.samplerTopK,
                              "top_p": generation.responseSampling.topP,
                              "filter_channel_content_from_kv_cache": true]])
    }

    private func ask(_ payload: [String: Any]) throws -> Int {
        try Task.checkCancellation()
        sequence += 1
        var request = payload
        request["id"] = requestID
        request["protocol_version"] = 1
        request["status"] = "measurement_required"
        request["measurement_id"] = sequence
        try Worker.emit(request)
        guard let line = readLine() else { throw MeasurementError.disconnected }
        let response = try JSONDecoder().decode(Response.self, from: Data(line.utf8))
        guard response.id == requestID, response.protocol_version == 1,
              response.measurement_id == sequence, response.status == "measurement_result" else {
            throw MeasurementError.protocolMismatch
        }
        if let error = response.error { throw MeasurementError.native(error) }
        guard let count = response.tokens else { throw MeasurementError.missingCount }
        return count
    }

    private struct Response: Decodable {
        let id: String
        let protocol_version: Int
        let measurement_id: Int
        let status: String
        let tokens: Int?
        let error: String?
    }
    enum MeasurementError: Error { case disconnected, protocolMismatch, missingCount, native(String) }
}
