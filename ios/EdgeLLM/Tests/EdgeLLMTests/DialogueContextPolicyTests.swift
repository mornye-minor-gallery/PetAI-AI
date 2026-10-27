import Foundation

@Test func aggregateEvaluationBudgetsKeepTheirExplicitComponentPolicy() throws {
    let data = Data(#"{"memoryTokens":20,"contextTokens":500,"outputTokens":50}"#.utf8)
    let budget = try JSONDecoder().decode(DialogueTokenBudget.self, from: data)
    #expect(budget.memoryTokens == 20)
    #expect(budget.outputTokens == 50)
    #expect(budget.limits == nil)
}
import Testing
import Foundation
@testable import EdgeLLM

@Test func productionDialogueReserves512OutputAnd512MemoryTokens() {
    let budget = SLMConfiguration.production.dialogueBudget
    #expect(budget.outputTokens == 512)
    #expect(budget.memoryTokens == 512)
    #expect(budget.contextTokens == 4096)
}

@Test func productionRecentContextDoesNotRollAtTwentyShortTurns() {
    var session = RoutedPersonaSessionContext()
    for index in 0..<40 {
        let appended = session.appendExchange(userMessage: "질문 \(index)", assistantMessage: "응.")
        #expect(appended)
    }
    #expect(session.chatTurns.count == 40)
    #expect(session.chatTurns.first?.userMessage == "질문 0")
    #expect(session.turns.count == 80)
}
