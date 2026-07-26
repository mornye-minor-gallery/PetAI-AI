import CryptoKit
import Foundation
import Testing
@testable import EdgeLLM

private func decodeTaggedChat(
    _ chunks: [String]
) -> (
    streamed: String,
    result: MemoryHeaderGateResult
) {
    var gate = MemoryHeaderGate()
    var streamed = ""
    for chunk in chunks {
        streamed += gate.consume(chunk).joined()
    }
    let result = gate.finish()
    if result.visibleText.hasPrefix(streamed) {
        streamed += result.visibleText.dropFirst(streamed.count)
    }
    return (streamed, result)
}

private func taggedChatStream(
    _ chunks: [String]
) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        for chunk in chunks {
            continuation.yield(chunk)
        }
        continuation.finish()
    }
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

@Test
func wrappedAxesPromptMatchesTheExperimentSourceBytes() {
    #expect(
        sha256(MemoryTaggedChatPrompt.wrappedAxesV1 + "\n")
            == MemoryTaggedChatPrompt.wrappedAxesV1SourceSHA256
    )
}

@Test
func canonicalAxesMapAllFourMemoryDecisions() {
    let cases: [(String, MemoryGateLabel)] = [
        ("save(P=0,E=0)", MemoryGateLabel.none),
        ("save(P=1,E=0)", .preference),
        ("save(P=0,E=1)", .event),
        ("save(P=1,E=1)", .both),
    ]

    for (header, expected) in cases {
        let decoded = decodeTaggedChat([
            "\(header)\n대화 답변",
        ])

        #expect(decoded.result.decision == expected)
        #expect(decoded.result.syntax == .canonical)
        #expect(decoded.result.controlText == "\(header)\n")
        #expect(decoded.streamed == "대화 답변")
    }
}

@Test
func canonicalHeaderSurvivesOneCharacterChunks() {
    let raw = "save(P=1,E=1)\n둘 다 기억할게."
    let decoded = decodeTaggedChat(raw.map(String.init))

    #expect(decoded.result.decision == .both)
    #expect(decoded.result.syntax == .canonical)
    #expect(decoded.streamed == "둘 다 기억할게.")
}

@Test
func canonicalHeaderSurvivesRequiredBoundarySplits() {
    let decoded = decodeTaggedChat([
        "save(",
        "P=1",
        ",E=1",
        ")",
        "\n",
        "둘 다 ",
        "기억할게.",
    ])

    #expect(decoded.result.decision == .both)
    #expect(decoded.result.syntax == .canonical)
    #expect(decoded.streamed == "둘 다 기억할게.")
}

@Test
func canonicalHeaderAndAnswerMayArriveInOneChunk() {
    let decoded = decodeTaggedChat([
        "save(P=0,E=1)\n어제 다녀왔구나.",
    ])

    #expect(decoded.result.decision == .event)
    #expect(decoded.result.syntax == .canonical)
    #expect(decoded.streamed == "어제 다녀왔구나.")
}

@Test
func canonicalHeaderMatchesPythonWhitespaceAndCRLFContract() {
    let decoded = decodeTaggedChat([
        " \tSaVe \t( P \t= 1 \t, E =\t0 )\r\n딸기를 좋아하는구나.",
    ])

    #expect(decoded.result.decision == .preference)
    #expect(decoded.result.syntax == .canonical)
    #expect(decoded.streamed == "딸기를 좋아하는구나.")
}

@Test
func invalidStructuredHeadersFailClosedAndHideTheirFirstLine() {
    let invalidHeaders = [
        "save(P=2,E=0)",
        "save(P=1,E=true)",
        "save(P=1)",
        "save(P=1,P=0,E=1)",
        "save(E=1,P=1)",
        "save(P=1,E=1",
        "save(P)",
    ]

    for header in invalidHeaders {
        let decoded = decodeTaggedChat([
            "\(header)\n일반 답변은 유지한다.",
        ])

        #expect(decoded.result.decision == nil)
        #expect(decoded.result.syntax == .malformed)
        #expect(decoded.streamed == "일반 답변은 유지한다.")
        #expect(!decoded.streamed.contains(header))
    }
}

@Test
func missingHeaderPreservesChatButProducesNoCommitDecision() async throws {
    var retryCalls = 0
    var streamed = ""
    let outcome = try await MemoryTaggedChatProcessor.run(
        primaryStream: {
            taggedChatStream(["그랬구나. 재미있었겠다."])
        },
        retryStream: {
            retryCalls += 1
            return taggedChatStream(["호출되면 안 됨"])
        },
        receiveVisibleText: { streamed += $0 }
    )

    #expect(outcome.primary.decision == nil)
    #expect(outcome.primary.syntax == .absent)
    #expect(outcome.commitDecision == nil)
    #expect(outcome.retryAttempted == false)
    #expect(retryCalls == 0)
    #expect(streamed == "그랬구나. 재미있었겠다.")
}

@Test
func validHeaderWithoutBodyRetriesExactlyOnceAndKeepsOriginalDecision()
    async throws
{
    var retryCalls = 0
    var streamed = ""
    let outcome = try await MemoryTaggedChatProcessor.run(
        primaryStream: {
            taggedChatStream(["save(P=1,E=0)"])
        },
        retryStream: {
            retryCalls += 1
            return taggedChatStream(["딸기를 정말 좋아하는구나."])
        },
        receiveVisibleText: { streamed += $0 }
    )

    #expect(retryCalls == 1)
    #expect(outcome.retryAttempted)
    #expect(outcome.retrySucceeded)
    #expect(outcome.primary.decision == .preference)
    #expect(outcome.commitDecision == .preference)
    #expect(streamed == "딸기를 정말 좋아하는구나.")
}

@Test
func emptyRetryFailsWithoutAllowingMemoryCommit() async throws {
    var retryCalls = 0
    var streamed = ""
    let outcome = try await MemoryTaggedChatProcessor.run(
        primaryStream: {
            taggedChatStream(["save(P=1,E=1)"])
        },
        retryStream: {
            retryCalls += 1
            return taggedChatStream([])
        },
        receiveVisibleText: { streamed += $0 }
    )

    #expect(retryCalls == 1)
    #expect(outcome.retryAttempted)
    #expect(outcome.retrySucceeded == false)
    #expect(outcome.hasVisibleResponse == false)
    #expect(outcome.commitDecision == nil)
    #expect(streamed.isEmpty)
}

@Test
func noneDecisionNeverClaimsACommit() async {
    let outcome = MemoryTaggedChatOutcome(
        primary: MemoryHeaderGateResult(
            decision: MemoryGateLabel.none,
            syntax: .canonical,
            rawText: "save(P=0,E=0)\n답변",
            visibleText: "답변",
            controlText: "save(P=0,E=0)\n"
        ),
        retry: nil
    )
    let guardLedger = MemoryTaggedChatCommitGuard()

    #expect(
        await guardLedger.claim(
            requestID: "request-none",
            outcome: outcome
        ) == nil
    )
}

@Test
func requestCanClaimAtMostOneSQLiteCommit() async {
    let outcome = MemoryTaggedChatOutcome(
        primary: MemoryHeaderGateResult(
            decision: .event,
            syntax: .canonical,
            rawText: "save(P=0,E=1)\n답변",
            visibleText: "답변",
            controlText: "save(P=0,E=1)\n"
        ),
        retry: nil
    )
    let guardLedger = MemoryTaggedChatCommitGuard()

    #expect(
        await guardLedger.claim(
            requestID: "same-request",
            outcome: outcome
        ) == .event
    )
    #expect(
        await guardLedger.claim(
            requestID: "same-request",
            outcome: outcome
        ) == nil
    )
}

@Test
func visibleOutputHasZeroControlLeaksAcrossCanonicalAndFailureCases() {
    let cases = [
        "save(P=0,E=0)\n답변",
        "save(P=1,E=0)\n답변",
        "save(P=0,E=1)\n답변",
        "save(P=1,E=1)\n답변",
        "save(P=2,E=1)\n답변",
        "save(P)\n답변",
    ]

    for raw in cases {
        let decoded = decodeTaggedChat([raw])
        #expect(decoded.streamed == "답변")
        #expect(!decoded.streamed.lowercased().contains("save("))
        #expect(!decoded.streamed.contains("P="))
        #expect(!decoded.streamed.contains("E="))
    }
}

@Test
func taggedChatDecisionRecordsWrappedAxesGemmaSource() {
    let decision = MemoryGateDecision.taggedChat(.both)

    #expect(decision.label == .both)
    #expect(
        decision.evidence(for: .preference).source == .gemmaHeader
    )
    #expect(
        decision.evidence(for: .event).source == .gemmaHeader
    )
    #expect(
        decision.classifierVersion
            == "gemma-header:wrapped-axes-v1"
    )
}
