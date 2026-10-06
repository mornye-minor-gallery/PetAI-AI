import Foundation
import Testing

@testable import EdgeLLM

@Test
func noCallInquiryDoesNotBecomeAnAlarmListRequest() async throws {
    let inquiryEmbedder = RoutingIntentEmbedder(response: .vector([0, 1]))
    let requestEmbedder = RoutingIntentEmbedder(response: .vector([1, 0]))
    let inquiryRouter = try makeIntentRouter(embedder: inquiryEmbedder)
    let requestRouter = try makeIntentRouter(embedder: requestEmbedder)

    #expect(
        try await inquiryRouter.route("내가 만든 알람 목록을 확인하는 기능도 지원해?")
            == .normal
    )
    #expect(
        try await requestRouter.route("내가 만들어 둔 알람 목록 보여줘.")
            == .tool(.listAlarms)
    )
    #expect(await inquiryEmbedder.count() == 1)
    #expect(await requestEmbedder.count() == 1)
}

@Test
func noCallOverridesLexicalToolsAndConflicts() async throws {
    let embedder = RoutingIntentEmbedder(response: .vector([0, 1]))
    let router = try makeIntentRouter(embedder: embedder)
    let utterances = [
        "걸음 수를 확인하는 기능이 있어?",
        "친구가 내일 아침 7시에 알람 맞춰줘라고 했어",
        "내 알람 목록 보여 주지 마",
        "10분 타이머 설정 기능은 어떻게 쓰는 거야?",
        "알림을 예약하는 기능도 지원해?",
        "내일 일정을 확인하는 방법이 궁금해",
        "일정 추가해줘라고 말하는 기능이 있으면 좋겠어",
        "내일 일정을 보여 주고 7시 알람도 맞춰 줘라고 말하면 어떻게 돼?",
    ]

    for utterance in utterances {
        #expect(KoreanNativeToolRouter().route(utterance) != .normal)
        #expect(try await router.route(utterance) == .normal)
    }
    #expect(await embedder.count() == utterances.count)
}

@Test
func callPreservesLexicalSelectionWhenPrototypesMiss() async throws {
    let embedder = RoutingIntentEmbedder(response: .vector([1, 0]))
    let router = try makeIntentRouter(embedder: embedder)
    let cases: [(String, NativeToolKind)] = [
        ("오늘 몇 걸음 걸었어?", .getStepCount),
        ("내일 아침 7시에 운동 알람 맞춰 줘", .createAlarm),
        ("내 알람 목록 보여 줘", .listAlarms),
        ("10분 타이머 만들어줘", .createTimer),
        ("오후 3시에 물 마시라고 알려 줘", .scheduleLocalNotification),
        ("내일 일정 알려 줘", .getCalendarEvents),
        ("내일 3시에 멘토링 일정 잡아 줘", .createCalendarEvent),
        ("다섯 분 뒤 알람 맞춰 줘", .createTimer),
    ]

    for (utterance, tool) in cases {
        #expect(try await router.route(utterance) == .tool(tool))
    }
    #expect(await embedder.count() == cases.count)
}

@Test
func callPreservesLexicalConflictAfterIntentClassification() async throws {
    let embedder = RoutingIntentEmbedder(response: .vector([1, 0]))
    let router = try makeIntentRouter(embedder: embedder)

    #expect(
        try await router.route("내일 일정을 보여 주고 다섯 분 뒤 알람 맞춰 줘")
            == .conflict([.createTimer, .getCalendarEvents])
    )
    #expect(await embedder.count() == 1)
}

@Test
func callUsesPrototypesForRequestsWithoutLexicalMatch() async throws {
    let embedder = RoutingIntentEmbedder(response: .vector([1, 0]))
    let router = try makeIntentRouter(embedder: embedder, prototype: [1, 0])
    let utterance = "열 개까지 숫자를 거꾸로 세어 줄래?"

    #expect(KoreanNativeToolRouter().route(utterance) == .normal)
    #expect(try await router.route(utterance) == .tool(.createTimer))
    #expect(await embedder.count() == 1)
}

@Test
func intentRouterSkipsEmbeddingForEmptyInput() async throws {
    let embedder = RoutingIntentEmbedder(response: .failure)
    let router = try makeIntentRouter(embedder: embedder)

    #expect(try await router.route(" \n\t") == .normal)
    #expect(await embedder.count() == 0)
}

@Test
func lexicalToolDoesNotHideEmbeddingFailureOrCancellation() async throws {
    let failedEmbedder = RoutingIntentEmbedder(response: .failure)
    let cancelledEmbedder = RoutingIntentEmbedder(response: .cancellation)
    let failedRouter = try makeIntentRouter(embedder: failedEmbedder)
    let cancelledRouter = try makeIntentRouter(embedder: cancelledEmbedder)

    await #expect(throws: NativeToolRoutingError.embeddingUnavailable) {
        _ = try await failedRouter.route("내일 아침 7시에 알람 맞춰 줘")
    }
    await #expect(throws: CancellationError.self) {
        _ = try await cancelledRouter.route("내 알람 목록 보여 줘")
    }
    #expect(await failedEmbedder.count() == 1)
    #expect(await cancelledEmbedder.count() == 1)
}

@Test
func lexicalToolDoesNotHideInvalidClassificationEmbedding() async throws {
    let cases: [(vector: [Float], error: NativeToolRoutingError)] = [
        ([1], .invalidEmbeddingDimension(expected: 2, actual: 1)),
        ([.nan, 0], .nonFiniteEmbedding(index: 0)),
    ]
    for item in cases {
        let embedder = RoutingIntentEmbedder(response: .vector(item.vector))
        let router = try makeIntentRouter(embedder: embedder)
        await #expect(throws: item.error) {
            _ = try await router.route("1분 타이머 맞춰줘")
        }
        #expect(await embedder.count() == 1)
    }
}

@Test
func noCallInquirySkipsToolGenerationAndProposalRegistration() async throws {
    let embedder = RoutingIntentEmbedder(response: .vector([0, 1]))
    let generator = InquiryToolGeneratorProbe()
    let coordinator = NativeToolProposalCoordinator { _ in .null }
    let harness = NativeToolProposalHarness(
        router: try makeIntentRouter(embedder: embedder),
        coordinator: coordinator,
        generator: generator
    )
    let outcome = try await harness.prepare(
        requestID: "inquiry",
        userMessage: "내가 만든 알람 목록을 확인하는 기능도 지원해?",
        promptContext: NativeToolPromptContext(
            currentDate: "2026-10-03",
            currentDateTime: "2026-10-03T12:00",
            timeZoneIdentifier: "Asia/Seoul"
        ),
        allowedTools: Set(NativeToolKind.allCases)
    )

    #expect(outcome == .normal)
    #expect(await generator.count() == 0)
    #expect(await coordinator.snapshot(requestID: "inquiry") == nil)
}

private actor RoutingIntentEmbedder: ClassificationEmbeddingProviding {
    enum Response: Sendable {
        case vector([Float])
        case failure
        case cancellation
    }

    nonisolated let modelID = NativeToolRouterArtifactRegistry.expectedModelID
    nonisolated let dimension = 2
    private let response: Response
    private var invocationCount = 0

    init(response: Response) {
        self.response = response
    }

    func embedClassification(_ text: String) throws -> [Float] {
        invocationCount += 1
        switch response {
        case .vector(let vector): return vector
        case .failure: throw NativeToolRoutingError.resourceMissing("test")
        case .cancellation: throw CancellationError()
        }
    }

    func count() -> Int { invocationCount }
}

private actor InquiryToolGeneratorProbe: NativeToolProposalGenerating {
    private var invocationCount = 0

    func generateFunctionCall(
        _ request: NativeToolGenerationRequest
    ) -> NativeToolFunctionCall {
        invocationCount += 1
        return NativeToolFunctionCall(
            name: NativeToolKind.listAlarms.rawValue,
            argumentsJSON: "{}"
        )
    }

    func count() -> Int { invocationCount }
}

// 분류기의 판단을 고정해 실행 의도와 도구 선택의 순서를 검증한다.
private func makeIntentRouter(
    embedder: any ClassificationEmbeddingProviding,
    prototype: [Float] = [0, 1]
) throws -> any NativeToolRouting {
    let pipeline = NativeToolRoutingPipeline(
        artifactID: "test-intent",
        actionability: try NativeToolActionabilityMLP(
            inputDimension: 2,
            hiddenUnits: 1,
            threshold: 0.5,
            dense0Weight: [1, 0],
            dense0Bias: [0],
            dense1Weight: [10],
            dense1Bias: -5
        ),
        selector: try NativeToolEmbeddingSelector(
            dimension: 2,
            routes: [NativeToolEmbeddingRouteDefinition(
                tool: .createTimer,
                threshold: 0.8,
                prototypeOffset: 0,
                prototypeCount: 1
            )],
            prototypes: prototype
        )
    )
    return EmbeddingMLPNativeToolRouter(embedder: embedder, pipeline: pipeline)
}
