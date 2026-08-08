import Foundation

public struct NativeToolGenerationRequest: Equatable, Sendable {
    public let selectedTool: NativeToolKind
    public let systemPrompt: String
    public let userMessage: String
    public let reasoningEnabled: Bool

    public init(
        selectedTool: NativeToolKind,
        systemPrompt: String,
        userMessage: String,
        reasoningEnabled: Bool = SLMConfiguration.production.generation
            .toolReasoningEnabled
    ) {
        self.selectedTool = selectedTool
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.reasoningEnabled = reasoningEnabled
    }
}

public protocol NativeToolProposalGenerating: Sendable {
    func generateFunctionCall(
        _ request: NativeToolGenerationRequest
    ) async throws -> NativeToolFunctionCall
}

public enum NativeToolProposalHarnessOutcome: Equatable, Sendable {
    case normal
    case conflict(message: String, tools: [NativeToolKind])
    case clarification(message: String)
    case proposal(
        draft: NativeToolProposal,
        proposal: ValidatedToolProposal,
        event: UnityToolStateEvent
    )
}

public struct NativeToolProposalHarness: Sendable {
    public static let conflictMessage = "한 번에 하나씩 요청해 주세요."

    private let router: KoreanNativeToolRouter
    private let promptRegistry: NativeToolPromptRegistry
    private let parser: NativeToolProposalParser
    private let validator: NativeToolProposalValidator
    private let localNotificationClarifier:
        LocalNotificationRequestClarifier
    private let coordinator: NativeToolProposalCoordinator
    private let generator: any NativeToolProposalGenerating
    private let configuration: SLMConfiguration

    public init(
        router: KoreanNativeToolRouter = KoreanNativeToolRouter(),
        promptRegistry: NativeToolPromptRegistry = NativeToolPromptRegistry(),
        parser: NativeToolProposalParser = NativeToolProposalParser(),
        validator: NativeToolProposalValidator = NativeToolProposalValidator(),
        localNotificationClarifier: LocalNotificationRequestClarifier =
            LocalNotificationRequestClarifier(),
        coordinator: NativeToolProposalCoordinator,
        generator: any NativeToolProposalGenerating,
        configuration: SLMConfiguration = .production
    ) {
        self.router = router
        self.promptRegistry = promptRegistry
        self.parser = parser
        self.validator = validator
        self.localNotificationClarifier = localNotificationClarifier
        self.coordinator = coordinator
        self.generator = generator
        self.configuration = configuration
    }

    public func prepare(
        requestID: String,
        userMessage: String,
        promptContext: NativeToolPromptContext
    ) async throws -> NativeToolProposalHarnessOutcome {
        switch router.route(userMessage) {
        case .normal:
            return .normal

        case .conflict(let tools):
            return .conflict(
                message: Self.conflictMessage,
                tools: tools
            )

        case .tool(let selectedTool):
            if selectedTool == .scheduleLocalNotification,
               let message = localNotificationClarifier.clarification(
                   for: userMessage
               )
            {
                return .clarification(message: message)
            }
            let prompt = try promptRegistry.prompt(for: selectedTool)
            let call = try await generator.generateFunctionCall(
                NativeToolGenerationRequest(
                    selectedTool: selectedTool,
                    systemPrompt: prompt.rendered(with: promptContext),
                    userMessage: userMessage,
                    reasoningEnabled: configuration.generation
                        .toolReasoningEnabled
                )
            )
            let proposal = try parser.parse(
                call,
                selectedTool: selectedTool,
                requestID: requestID
            )
            let validated = try validator.validate(proposal)
            let event = try await coordinator.register(validated)
            return .proposal(
                draft: proposal,
                proposal: validated,
                event: event
            )
        }
    }
}
