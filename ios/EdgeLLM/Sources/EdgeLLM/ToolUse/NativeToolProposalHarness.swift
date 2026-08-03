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
        reasoningEnabled: Bool = true
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
    case proposal(
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
    private let coordinator: NativeToolProposalCoordinator
    private let generator: any NativeToolProposalGenerating

    public init(
        router: KoreanNativeToolRouter = KoreanNativeToolRouter(),
        promptRegistry: NativeToolPromptRegistry = NativeToolPromptRegistry(),
        parser: NativeToolProposalParser = NativeToolProposalParser(),
        validator: NativeToolProposalValidator = NativeToolProposalValidator(),
        coordinator: NativeToolProposalCoordinator,
        generator: any NativeToolProposalGenerating
    ) {
        self.router = router
        self.promptRegistry = promptRegistry
        self.parser = parser
        self.validator = validator
        self.coordinator = coordinator
        self.generator = generator
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
            let prompt = try promptRegistry.prompt(for: selectedTool)
            let call = try await generator.generateFunctionCall(
                NativeToolGenerationRequest(
                    selectedTool: selectedTool,
                    systemPrompt: prompt.rendered(with: promptContext),
                    userMessage: userMessage,
                    reasoningEnabled: true
                )
            )
            let proposal = try parser.parse(
                call,
                selectedTool: selectedTool,
                requestID: requestID
            )
            let validated = try validator.validate(proposal)
            let event = try await coordinator.register(validated)
            return .proposal(proposal: validated, event: event)
        }
    }
}
