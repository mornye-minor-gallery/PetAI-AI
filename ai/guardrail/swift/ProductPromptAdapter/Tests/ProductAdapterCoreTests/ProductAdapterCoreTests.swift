import Testing
@testable import ProductAdapterCore

@Test
func snapshotUsesProductionPromptAndSampling() throws {
    let snapshot = try ProductPromptSnapshot()
    #expect(snapshot.configurationID == "petai-slm-v1")
    #expect(snapshot.systemPrompt.contains("save(P=X,E=Y)"))
    #expect(snapshot.temperature == 0.7)
    #expect(snapshot.topK == 40)
    #expect(snapshot.maxOutputTokens == 4_096)
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
