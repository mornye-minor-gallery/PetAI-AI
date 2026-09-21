import Foundation

/// Evaluation-only overrides; an omitted profile keeps the product defaults.
struct EvaluationSampling: Codable {
    let temperature: Double
    let topK: Int
    let topP: Double

    enum CodingKeys: String, CodingKey {
        case temperature
        case topK = "top_k"
        case topP = "top_p"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try values.decode(Double.self, forKey: .temperature)
        topK = try values.decode(Int.self, forKey: .topK)
        topP = try values.decode(Double.self, forKey: .topP)
        guard temperature.isFinite, temperature >= 0, topK > 0, (0...1).contains(topP) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Sampling requires temperature >= 0, top_k > 0, and top_p in 0...1"))
        }
    }
}
