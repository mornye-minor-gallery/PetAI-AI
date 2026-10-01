import Foundation
import EdgeLLM

struct AndroidChatPaths: Decodable, Sendable {
    let assetsDirectory: String
    let modelsDirectory: String
    let supportDirectory: String
    let cacheDirectory: String
}

struct AndroidChatPlatform: ChatPlatformServices {
    let paths: AndroidChatPaths
    let tools: any ChatPlatformTools = AndroidPendingTools()
    var personaEnabled: Bool { true }
    var assets: URL { URL(fileURLWithPath: paths.assetsDirectory) }

    func refreshModelAssets() async {}
    func resolveModelAssets() async throws -> RuntimeModelAssets {
        guard let installed = DownloadedModelAssets.installed(in: URL(fileURLWithPath: paths.modelsDirectory)) else {
            throw AndroidHostError.modelsNotInstalled
        }
        return installed
    }
    func missingAsset() async throws -> NativeAssetKind? {
        DownloadedModelAssets.installed(in: URL(fileURLWithPath: paths.modelsDirectory)) == nil ? .languageModel : nil
    }
    func loadContent() throws -> ChatContentResources {
        let content = try DialogueContent.load(url: assets.appendingPathComponent("dialogue-content.json"))
        let retrieval = try content.retrieval.map {
            try DialogueRetrievalResources(directory: assets, characterID: content.id,
                                           reactions: $0.reactions, worldLore: $0.worldLore)
        }
        return .init(content: content, retrieval: retrieval)
    }
    func recentTurnStore() throws -> DialogueSessionFileStore {
        .init(fileURL: URL(fileURLWithPath: paths.supportDirectory).appendingPathComponent("recent-turns.json"))
    }
    func selectAsset(_ kind: NativeAssetKind) async throws -> URL { throw AndroidHostError.notReady }
    func importAsset(_ url: URL, kind: NativeAssetKind) async throws { throw AndroidHostError.notReady }
    func share(_ file: URL) async throws { throw AndroidHostError.notReady }
    func showExportError(_ message: String) async { AndroidChatHost.shared.emitError(message) }
    func lockForTestReset() async throws { throw AndroidHostError.notReady }
    func resetTestData(removeModels: Bool) async throws { throw AndroidHostError.notReady }
}

enum AndroidHostError: LocalizedError {
    case notReady, alreadyConfigured, notConfigured, modelsNotInstalled
    var errorDescription: String? {
        switch self {
        case .notReady: "Android에서는 준비 중인 기능입니다."
        case .modelsNotInstalled: "모델 다운로드를 완료한 뒤 다시 시도해 주세요."
        case .alreadyConfigured: "Android chat is already configured with different paths."
        case .notConfigured: "Android chat paths must be configured before initialization."
        }
    }
}

struct AndroidPendingTools: ChatPlatformTools {
    let supportedTools: Set<NativeToolKind> = []
    let unsupportedMessage = "Android에서는 준비 중인 기능입니다."
    func enrich(_ base: UserProfileContext, allowedTools: Set<NativeToolKind>) async -> UserProfileContext { base }
    func confirm(_ draft: NativeToolProposal) async throws -> NativeToolProposal { throw AndroidHostError.notReady }
    func cancelConfirmation() async {}
    func execute(_ proposal: ValidatedToolProposal) async throws -> JSONValue { throw AndroidHostError.notReady }
}
