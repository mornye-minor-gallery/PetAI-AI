import Foundation
import Testing
@testable import EdgeLLM

@Test func reactionQueryGateChoosesCurrentOrContextFromCurrentMessage() throws {
    let examples = (0..<5).map { _ in ["current": "오늘 저녁 메뉴 추천해줘", "nontopical": false] as [String: Any] }
        + (0..<5).map { _ in ["current": "그거는 어떻게 해?", "nontopical": true] as [String: Any] }
    let metadata = try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "policyID": "ensemble-bb81762edc8a",
        "embeddingIdentity": "fixture",
        "dimension": 2,
        "vectorsSHA256": "fixture",
        "source": ["indexSHA256": "fixture"],
        "examples": examples,
    ])
    let vectors = Array(repeating: [Float(1), Float(0)], count: 5).flatMap { $0 }
        + Array(repeating: [Float(-1), Float(0)], count: 5).flatMap { $0 }
    let gate = try ReactionQueryGate(metadata: metadata, vectors: vectors)

    #expect(try gate.select(current: "오늘 저녁 메뉴 추천해줘", embedding: [1, 0], embeddingIdentity: "fixture") == .one)
    #expect(try gate.select(current: "그거는 어떻게 해?", embedding: [-1, 0], embeddingIdentity: "fixture") == .three)
    #expect(ReactionFrameIndex.query(history: ["이전 질문", "이전 답변"], current: "지금 질문", messageCount: .one) == "지금 질문")
    #expect(ReactionFrameIndex.query(history: ["이전 질문", "이전 답변"], current: "지금 질문", messageCount: .three) == "이전 질문\n이전 답변\n지금 질문")
    #expect(throws: (any Error).self) {
        try gate.select(current: "오늘 저녁 메뉴 추천해줘", embedding: [1, 0], embeddingIdentity: "other")
    }
}

@Test func reactionQueryGateMatchesFrozenValidationWhenProvided() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["PETAI_REACTION_GATE_ARTIFACT"],
          let fixture = environment["PETAI_REACTION_GATE_VALIDATION"] else { return }
    struct Case: Decodable {
        let current: String
        let embedding: [Float]
        let expected: Int
    }
    struct Probe: Decodable {
        let embeddingIdentity: String
        let cases: [Case]
    }
    let probe = try JSONDecoder().decode(Probe.self, from: Data(contentsOf: URL(fileURLWithPath: fixture)))
    let gate = try ReactionQueryGate.load(directory: URL(fileURLWithPath: directory))
    #expect(probe.cases.count == 240)
    let predictions = try probe.cases.map {
        try gate.select(current: $0.current, embedding: $0.embedding,
                        embeddingIdentity: probe.embeddingIdentity).rawValue
    }
    #expect(zip(predictions, probe.cases).allSatisfy { $0 == $1.expected })
}
