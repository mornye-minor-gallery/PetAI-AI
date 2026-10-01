import EdgeLLM
import Foundation

public enum AppFixtures {
    // Synthetic, non-private data; production composition and state code are unchanged.
    public static let core = "너는 엘레나야. 사용자와 한국어로 짧고 자연스럽게 대화해. 답변은 한 문장으로 해."
    public static func context(count: Int) throws -> RoutedPersonaSessionContext {
        var context = RoutedPersonaSessionContext(maximumTurnCount: 20)
        for index in 1...max(1, count) where index <= count {
            let id = "fixture-\(index)"
            _ = try context.beginRequest(requestID: id, userMessage: "질문-\(index)")
            try context.finishRequest(requestID: id, status: .completed, assistantMessage: "응, 기억해-\(index)")
        }
        return context
    }
    public static func prepare(_ context: RoutedPersonaSessionContext, id: String, message: String,
                               dynamic: Bool) throws -> PreparedDialogue {
        let snapshot = try context.snapshot(requestID: id)
        let date = Date(timeIntervalSince1970: 0)
        let observation = MemoryObservation(id: "memory-1", turnID: "old-turn", sessionID: "fixture",
            sequence: 1, scope: .init(userID: "fixture", characterID: "elena"), occurredAt: date,
            rawText: dynamic ? "사용자는 주말에 등산을 가고 싶어 한다." : "사용자는 퍼즐 게임을 좋아한다.",
            labelEvidence: [MemoryLabelEvidence](), createdAt: date)
        return try DialoguePromptComposer.prepare(input: .init(
            persona: .init(core: core), activeCard: dynamic ? "지금은 밤이고 비가 온다." : "지금은 맑은 아침이다.",
            profile: .init(userName: "테스터", rhythmGamePlayCount: 1,
                           rhythmGameBestScore: dynamic ? 9000 : 1000),
            history: snapshot.history, memories: [.init(observation: observation, score: 0.9, rank: 1)],
            currentMessage: message, session: snapshot))
    }
}
