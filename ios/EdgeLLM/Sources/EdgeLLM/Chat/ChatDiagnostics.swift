import Foundation

public struct ChatDiagnostics: Sendable {
    public let mark: @Sendable (String, [String: String]) -> Void
    public let prepared: @Sendable (String, PersonaSceneRoute, Int, PreparedDialogue) -> Void
    public let generated: @Sendable (String, Bool) async -> Void

    public init(mark: @escaping @Sendable (String, [String: String]) -> Void,
                prepared: @escaping @Sendable (String, PersonaSceneRoute, Int, PreparedDialogue) -> Void,
                generated: @escaping @Sendable (String, Bool) async -> Void) {
        self.mark = mark
        self.prepared = prepared
        self.generated = generated
    }
}
