import Foundation

/// App-authored presentation of the completed visible answer, not another model call.
/// No money, commands, prompt tags or memory-control text are interpreted here.
public struct ChatReplyPresentation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let source: String
    public let kind: String
    public let face: String
    public var memory: ChatMemoryCandidate? = nil

    private init(kind: String, face: String) {
        schemaVersion = 1
        source = "native-visible-text-v1"
        self.kind = kind
        self.face = face
    }

    public static func dialogue(visibleText: String) -> Self {
        // Display-only heuristic, deliberately conservative; not a semantic emotion model.
        let face: String
        if ["깜짝", "놀랐", "놀랍", "정말이야?", "설마"].contains(where: visibleText.contains) {
            face = "surprise"
        } else if ["부끄", "쑥스", "두근"].contains(where: visibleText.contains) {
            face = "shy"
        } else if ["고마워", "고맙", "반가워", "기뻐", "좋아해"].contains(where: visibleText.contains) {
            face = "wink"
        } else {
            face = "smile"
        }
        return Self(kind: "dialogue", face: face)
    }

    public static let tool = Self(kind: "tool", face: "smile")
}
