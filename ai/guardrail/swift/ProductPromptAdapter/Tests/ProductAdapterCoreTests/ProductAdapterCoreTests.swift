import Testing
import Foundation
import EdgeLLM
@testable import ProductAdapterCore

@Test
func snapshotUsesProductionPromptAndSampling() throws {
    let content = try DialogueContent.load(data: Data(#"{"id":"test","name":"별","persona":"{{char}}는 검사 전용 캐릭터입니다."}"#.utf8))
    let snapshot = try ProductPromptSnapshot(content: content)
    #expect(snapshot.configurationID == "petai-slm-v1")
    #expect(snapshot.systemPrompt.contains("save(P=X,E=Y)"))
    #expect(snapshot.temperature == 0.7)
    #expect(snapshot.topK == 40)
    #expect(snapshot.maxOutputTokens == SLMConfiguration.production.dialogueBudget.outputTokens)
    #expect(snapshot.systemPrompt.contains("별는 검사 전용 캐릭터입니다."))
    #expect(snapshot.thinkingEnabled == false)
}

@Test
func normalizerUsesProductMemoryHeaderGate() {
    let output = ProductResponseNormalizer.normalize(
        RawResponseRecord(
            caseID: "case-1",
            rawText: "save(P=0,E=0)\n반가워."
        )
    )
    #expect(output.visibleText == "반가워.")
    #expect(output.headerSyntax == "canonical")
    #expect(output.memoryDecision == "none")
}
