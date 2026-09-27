import Foundation

public struct NativeChatEvent: Encodable, Sendable {
    public let type: String
    public var requestId: String?
    public var text: String?
    public var code: String?
    public var message: String?
    public var homeSteps: HomeStepObservation?
    public var presentation: ChatReplyPresentation?
    public var worldInfoAutomation: [String]?
    public var recentEntries: [NativeRestoredDialogueEntry]?
}

public struct NativeRestoredDialogueEntry: Encodable, Sendable {
    public let kind: String
    public let id: String
    public let userMessage: String?
    public let assistantMessage: String?
    public let status: String?
    public let text: String?

    init(_ entry: RecentDialogueEntry) {
        switch entry {
        case .request(let turn):
            kind = "request"
            id = turn.requestID
            userMessage = turn.userMessage
            assistantMessage = turn.assistantMessage
            status = turn.status.rawValue
            text = nil
        case .homeLine(let line):
            kind = "homeLine"
            id = line.id
            userMessage = nil
            assistantMessage = nil
            status = nil
            text = line.text
        }
    }
}

struct NativeHomeLineRequest: Decodable {
    public let id: String
    public let text: String
}

public enum NativePreparationContext {
    @TaskLocal public static var requestID: String?
}

struct NativeSendRequest: Decodable {
    public let requestId: String
    public let prompt: String
    public let thinkingEnabled: Bool?
    public let userProfileContext: NativeUserProfileContext?
    public let worldInfoContext: NativeWorldInfoInput?
}

struct NativeUserProfileContext: Decodable, Sendable {
    public let userName: String
    public let characterId: String
    public let rhythmGamePlayCount: Int
    public let rhythmGameBestScore: Int
    public let toolAccess: [NativeToolAccessContext]
}

struct NativeToolAccessContext: Decodable, Sendable {
    public let tool: String
    public let unlockSource: String
    public let unlocked: Bool
}

struct NativeToolAccessPolicy: Sendable {
    private let accessByTool: [NativeToolKind: NativeToolAccessContext]

    init(_ values: [NativeToolAccessContext]) {
        var normalized: [NativeToolKind: NativeToolAccessContext] = [:]
        for value in values {
            guard let tool = NativeToolKind(rawValue: value.tool) else {
                continue
            }
            normalized[tool] = value
        }
        accessByTool = normalized
    }

    public var allowedTools: Set<NativeToolKind> {
        Set(accessByTool.compactMap { tool, value in
            value.unlocked ? tool : nil
        })
    }

    public var unlockedSources: [String] {
        Array(Set(accessByTool.values.compactMap {
            $0.unlocked ? $0.unlockSource : nil
        })).sorted()
    }

    func unlockSource(for tool: NativeToolKind) -> String? {
        accessByTool[tool]?.unlockSource
    }
}
