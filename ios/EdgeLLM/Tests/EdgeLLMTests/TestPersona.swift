#if os(Android)
import Crypto
#else
import CryptoKit
#endif
import Foundation
@testable import EdgeLLM

/// Synthetic input, deliberately unrelated to the product story.
func testPersona() throws -> RoutedPersonaPromptSet {
    try testPersonaRegistry().load()
}

func testPersonaRegistry(modified: Bool = false) -> RoutedPersonaPromptRegistry {
    let core = Data("{{char}}는 검사 전용 캐릭터다.".utf8)
    let cards = Dictionary(uniqueKeysWithValues: PersonaSceneRoute.allCases.map {
        ($0.rawValue, PersonaSceneCard(facetID: nil, card: $0 == .general ? nil : "검사 장면 지시"))
    })
    let encoded = try! JSONEncoder().encode(cards)
    let data = ["persona_core.md": core, "scene_cards.json": encoded]
    let hashes = data.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    return RoutedPersonaPromptRegistry(expectedChecksums: hashes) { name in
        modified ? Data("modified".utf8) : data[name]
    }
}
