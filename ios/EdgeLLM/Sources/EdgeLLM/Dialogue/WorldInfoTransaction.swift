import Foundation

/// A proposed update, delivered with the prompt and committed once with the reply.
/// Automation identifiers are data for the game host, never executable tool calls.
public struct WorldInfoTransaction: Codable, Equatable, Sendable {
    public let state: WorldInfoState
    public let text: WorldInfoTextContext
    public let automationIDs: [String]
    public let outlets: [String: String]
    public init(state: WorldInfoState, text: WorldInfoTextContext, automationIDs: [String] = [], outlets: [String: String] = [:]) {
        self.state = state; self.text = text; self.automationIDs = automationIDs; self.outlets = outlets
    }
}
