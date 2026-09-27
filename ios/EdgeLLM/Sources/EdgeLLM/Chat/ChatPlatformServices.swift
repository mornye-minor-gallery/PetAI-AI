import Foundation

/// The host supplies OS work. Conversation state and persistence ordering stay in the controller.
public protocol ChatPlatformServices: Sendable {
    func refreshModelAssets() async
    func missingAsset() async throws -> NativeAssetKind?
    func resolveModelAssets() async throws -> RuntimeModelAssets
    func selectAsset(_ kind: NativeAssetKind) async throws -> URL
    func importAsset(_ url: URL, kind: NativeAssetKind) async throws
    func loadContent() throws -> ChatContentResources
    func recentTurnStore() throws -> DialogueSessionFileStore
    var personaEnabled: Bool { get }
    var tools: any ChatPlatformTools { get }
    func share(_ file: URL) async throws
    func showExportError(_ message: String) async
    func lockForTestReset() async throws
    func resetTestData(removeModels: Bool) async throws
}

public protocol ChatPlatformTools: Sendable {
    var supportedTools: Set<NativeToolKind> { get }
    var unsupportedMessage: String { get }
    func enrich(_ base: UserProfileContext, allowedTools: Set<NativeToolKind>) async -> UserProfileContext
    func confirm(_ draft: NativeToolProposal) async throws -> NativeToolProposal
    func cancelConfirmation() async
    func execute(_ proposal: ValidatedToolProposal) async throws -> JSONValue
}

public struct ChatContentResources: Sendable {
    public let content: DialogueContent
    public let retrieval: DialogueRetrievalResources?
    public init(content: DialogueContent, retrieval: DialogueRetrievalResources? = nil) {
        self.content = content
        self.retrieval = retrieval
    }
}

public protocol ChatInferenceRuntime: LLMRuntime, NativeToolProposalGenerating {
    func prepareDialogue(input: DialoguePromptInput, policy: DialoguePromptPolicy,
                         thinkingEnabled: Bool) async throws -> PreparedDialogue
    func generateStream(prompt: String, thinkingEnabled: Bool) async throws -> AsyncThrowingStream<String, Error>
    func generateIsolated(systemPrompt: String, userMessage: String,
                          sampling: SLMConfiguration.Sampling?,
                          thinkingEnabled: Bool?, maxOutputTokens: Int?) async throws -> String
    func saveCompletedDialogueCheckpoint() async
    func eraseCheckpoint() async throws
}

public protocol ChatMemoryService: ClassificationEmbeddingProviding {
    func prepare(modelURL: URL, tokenizerURL: URL) async throws
    func close() async
    func recall(_ request: MemorySearchRequest) async throws -> [RetrievedMemoryObservation]
    func remember(_ request: MemoryWriteRequest, decision: MemoryGateDecision) async throws -> MemoryRememberResult
    func searchEmbeddingIdentity() async throws -> String
    func embedWorldInfoQuery(_ text: String) async throws -> [Float]
    func searchWorldInfo(entries: [WorldInfoEntry], newestMessages: [String],
                         settings: WorldInfoVectorSettings) async throws -> [WorldInfoVectorMatch]
    func allActiveObservations() async throws -> [MemoryObservation]
    func eraseAllMemories() async throws
}

public enum NativeAssetKind: Sendable {
    case languageModel, embeddingModel, tokenizer
    public var requiredCode: String {
        switch self {
        case .languageModel: "language_model_required"
        case .embeddingModel: "embedding_model_required"
        case .tokenizer: "embedding_tokenizer_required"
        }
    }
    public var requiredMessage: String {
        switch self {
        case .languageModel: "대화 모델 파일이 필요합니다."
        case .embeddingModel: "기억 모델 파일이 필요합니다."
        case .tokenizer: "기억 모델의 토크나이저 파일이 필요합니다."
        }
    }
}

public enum UnityBridgeError: LocalizedError {
    case invalidRequest, modelSelectionCancelled, presenterUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "Unity sent an invalid chat request."
        case .modelSelectionCancelled: "Model selection was cancelled."
        case .presenterUnavailable: "The platform presenter is unavailable."
        }
    }
}

public enum NativeToolConfirmationError: Error, Equatable {
    case cancelled, presenterUnavailable, unsupportedTool(NativeToolKind)
}

/// Lightweight operational logging; the host chooses the platform log destination.
struct ChatLogger: Sendable {
    let write: @Sendable (String) -> Void
    func notice(_ text: String) { write(text) }
    func debug(_ text: String) { write(text) }
    func error(_ text: String) { write(text) }
}
