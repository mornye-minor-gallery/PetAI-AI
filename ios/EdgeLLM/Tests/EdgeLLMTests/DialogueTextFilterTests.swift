import Testing
@testable import EdgeLLM

private func filterTestStream(_ chunks: [String]) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
}

@Test func dialogueFilterPreservesAllowedScalarsAndIsIdempotent() {
    let filter = DialogueTextFilter()
    let allowed = "가힣 ㄱㅎㅏㅣ 한 AZaz09\t\r\n.,!?;:'\"()[]-~…=+/%"
    #expect(filter.apply(to: allowed) == allowed)
    let output = filter.apply(to: "안녕😊日本語مرحبا🎉👩🏽‍💻❤️!\u{200B}\u{202E} OK")
    #expect(output == "안녕! OK")
    #expect(filter.apply(to: output) == output)
    // The policy filters scalars: an emoji keycap's ASCII digit remains a digit.
    #expect(filter.apply(to: "1️⃣") == "1")
}

@Test func dialogueFilterStreamsIdenticallyAtEveryScalarBoundary() async throws {
    let body = "한글👩🏽‍💻 좋아! 🇰🇷1️⃣"
    for classified in [false, true] {
        let raw = (classified ? "save(P=1,E=0)\n" : "") + body
        let scalars = Array(raw.unicodeScalars)
        for split in 0...scalars.count {
            let left = String(String.UnicodeScalarView(scalars[..<split]))
            let right = String(String.UnicodeScalarView(scalars[split...]))
            var streamed = ""
            var retries = 0
            let result = try await MemoryTaggedChatProcessor.run(
                configuration: .init(memoryClassification: classified),
                primaryStream: { filterTestStream([left, right]) },
                retryStream: { retries += 1; return filterTestStream([]) },
                receiveVisibleText: { streamed += $0 }
            )
            #expect(result.primary.rawText == raw)
            #expect(result.visibleText == "한글 좋아! 1")
            #expect(streamed == result.visibleText)
            #expect(retries == 0)
            #expect(result.primary.decision == (classified ? .preference : nil))
            if classified { #expect(result.primary.controlText.contains("save(P=1,E=0)")) }
        }
    }
}

@Test func dialogueFilterEmptyBodyUsesExistingRetryPolicy() async throws {
    for classified in [false, true] {
        var retries = 0
        var streamed = ""
        let result = try await MemoryTaggedChatProcessor.run(
            configuration: .init(memoryClassification: classified),
            primaryStream: { filterTestStream([(classified ? "save(P=1,E=0)\n" : "") + "🎉日本語"]) },
            retryStream: { retries += 1; return filterTestStream(["괜찮아😊."]) },
            receiveVisibleText: { streamed += $0 }
        )
        #expect(retries == (classified ? 1 : 0))
        #expect(result.hasVisibleResponse == classified)
        #expect(result.visibleText == (classified ? "괜찮아." : ""))
        #expect(streamed == result.visibleText)
        #expect(result.commitDecision == (classified ? .preference : nil))
    }
}

@Test func dialogueFilterEmptyRetryNeverCommitsMemory() async throws {
    let result = try await MemoryTaggedChatProcessor.run(
        primaryStream: { filterTestStream(["save(P=1,E=1)\n🎉"]) },
        retryStream: { filterTestStream(["👩🏽‍💻"]) },
        receiveVisibleText: { #expect($0.isEmpty) }
    )
    #expect(result.retryAttempted)
    #expect(!result.hasVisibleResponse)
    #expect(result.commitDecision == nil)
    #expect(result.primary.rawText == "save(P=1,E=1)\n🎉")
    #expect(result.retry?.rawText == "👩🏽‍💻")
}
