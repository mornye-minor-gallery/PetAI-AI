import Foundation

/// One accepted user request. A partial answer remains visible but is never a completed exchange.
public struct ChatTurn: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case inProgress, completed, cancelled, failed
    }

    public let requestID: String
    public let userMessage: String
    public internal(set) var assistantMessage: String
    public internal(set) var status: Status

    init(requestID: String, userMessage: String, assistantMessage: String = "", status: Status) {
        self.requestID = requestID
        self.userMessage = userMessage
        self.assistantMessage = assistantMessage
        self.status = status
    }

    var visibleMessages: [RoutedPersonaSessionContext.Turn] {
        typealias Message = RoutedPersonaSessionContext.Turn
        var result: [Message] = []
        if !userMessage.isEmpty {
            let noAnswer = assistantMessage.isEmpty && status != .completed && status != .inProgress
            let text = noAnswer ? userMessage + "\n[이 요청은 \(status == .cancelled ? "취소" : "오류")되어 답변이 없었음]" : userMessage
            result.append(.init(role: .user, text: text))
        }
        if !assistantMessage.isEmpty {
            let text = status == .cancelled || status == .failed
                ? assistantMessage + "\n[이 답변은 \(status == .cancelled ? "취소로 중단" : "오류로 중단")됨]"
                : assistantMessage
            result.append(.init(role: .assistant, text: text))
        }
        return result
    }
}
