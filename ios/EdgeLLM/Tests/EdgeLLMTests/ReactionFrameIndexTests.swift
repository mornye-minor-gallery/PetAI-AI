import Foundation
import Testing
@testable import EdgeLLM

@Test func reactionQueryUsesThreeChronologicalMessages() {
    #expect(ReactionFrameIndex.query(history: ["old", "question", "answer"], current: "follow up") == "question\nanswer\nfollow up")
}

@Test func reactionSearchAlwaysSelectsOneAndMapsExampleToFrame() throws {
    let json = #"{"version":1,"characterID":"test","embeddingIdentity":"fixture","dimension":2,"rows":[0,1,1],"frames":[{"id":"a","goal":"listen","shape":"respond","example":{"user":"hi","assistant":"hello"}},{"id":"b","goal":"ask","shape":"question","example":{"user":"hi","assistant":"what?"}}]}"#
    let index = try ReactionFrameIndex(metadata: Data(json.utf8), vectors: [-1, 0, 0, -1, -0.8, -0.6])
    let result = try index.search(query: [1, 0], embeddingIdentity: "fixture")
    #expect(result.frame.id == "b")
    #expect(result.score == 0)
    #expect(throws: (any Error).self) { try index.search(query: [1,0], embeddingIdentity: "other") }
    #expect(throws: (any Error).self) { try index.search(query: [0,0], embeddingIdentity: "fixture") }
}
