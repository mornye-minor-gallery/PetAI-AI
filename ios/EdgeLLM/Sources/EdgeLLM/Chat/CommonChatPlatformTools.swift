import Foundation

/// Host adapters own OS permissions and side effects; clock reads work on both platforms.
struct CommonChatPlatformTools: ChatPlatformTools {
    let platform: any ChatPlatformTools

    var supportedTools: Set<NativeToolKind> { platform.supportedTools.union([.getCurrentTime]) }
    var unsupportedMessage: String { platform.unsupportedMessage }

    func enrich(_ base: UserProfileContext, allowedTools: Set<NativeToolKind>) async -> UserProfileContext {
        await platform.enrich(base, allowedTools: allowedTools)
    }

    func confirm(_ draft: NativeToolProposal) async throws -> NativeToolProposal {
        try await platform.confirm(draft)
    }

    func cancelConfirmation() async { await platform.cancelConfirmation() }

    func execute(_ proposal: ValidatedToolProposal) async throws -> JSONValue {
        if proposal.tool == .getCurrentTime {
            return try CurrentTimeTool().execute(proposal)
        }
        return try await platform.execute(proposal)
    }
}
