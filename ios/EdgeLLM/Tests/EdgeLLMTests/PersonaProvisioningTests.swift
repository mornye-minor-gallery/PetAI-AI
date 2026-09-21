import Foundation
import Testing
@testable import EdgeLLM

@Test func personaRequiresExplicitProvisioning() {
    #expect(throws: RoutedPersonaPromptRegistryError.notConfigured) {
        _ = try RoutedPersonaPromptRegistry().load()
    }
}

@Test func explicitPersonaKeepsOtherCharacterNamesIntact() throws {
    let prompts = RoutedPersonaPromptSet(core: "Elena는 예시 문서의 저자다.", sceneCards: [:])
    let output = prompts.responseSystemPrompt(activeCard: nil, userProfileContext: .init(characterName: "검사자"))
    #expect(output.contains("Elena는 예시 문서의 저자다."))
}
