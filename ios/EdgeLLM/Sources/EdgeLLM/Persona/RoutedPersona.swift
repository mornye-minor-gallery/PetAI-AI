import CryptoKit
import Foundation

public enum PersonaSceneRoute: String, CaseIterable, Equatable, Sendable {
    case firstSignal = "FIRST_SIGNAL"
    case firstArrival = "FIRST_ARRIVAL"
    case firstHome = "FIRST_HOME"
    case earthTerm = "EARTH_TERM"
    case earthFood = "EARTH_FOOD"
    case earthRelation = "EARTH_RELATION"
    case ambiguousCause = "AMBIG_CAUSE"
    case ambiguousChoice = "AMBIG_CHOICE"
    case returnSignal = "RETURN_SIGNAL"
    case returnSmile = "RETURN_SMILE"
    case returnFuture = "RETURN_FUTURE"
    case returnFear = "RETURN_FEAR"
    case supportSelfBlame = "SUPPORT_SELF_BLAME"
    case supportListen = "SUPPORT_LISTEN"
    case supportCompany = "SUPPORT_COMPANY"
    case supportRest = "SUPPORT_REST"
    case playfulSmile = "PLAYFUL_SMILE"
    case playfulClaim = "PLAYFUL_CLAIM"
    case playfulCompass = "PLAYFUL_COMPASS"
    case general = "GENERAL"
}

public struct PersonaSceneCard: Codable, Equatable, Sendable {
    public let facetID: String?
    public let card: String?

    enum CodingKeys: String, CodingKey {
        case facetID = "facet_id"
        case card
    }
}

public struct RoutedPersonaPromptSet: Equatable, Sendable {
    public let core: String
    public let sceneCards: [PersonaSceneRoute: PersonaSceneCard]

    public init(core: String, sceneCards: [PersonaSceneRoute: PersonaSceneCard] = [:]) {
        self.core = core
        self.sceneCards = sceneCards
    }

    public func card(scene: PersonaSceneRoute) -> String? {
        return sceneCards[scene]?.card
    }

    // Used when preparing the initial conversation before a user message exists.
    public func responseSystemPrompt(
        activeCard: String?,
        userProfileContext: UserProfileContext = UserProfileContext(),
        configuration: PersonaResponseConfiguration = .production
    ) -> String {
        DialoguePromptRenderer.systemPrompt(prompts: self, activeCard: activeCard,
            userProfileContext: userProfileContext, configuration: configuration)
    }

}

public enum RoutedPersonaPromptRegistryError: Error, Equatable, Sendable {
    case notConfigured
    case resourceMissing(String)
    case invalidUTF8(String)
    case checksumMismatch(
        resource: String,
        expected: String,
        actual: String
    )
    case invalidSceneCards
}

public struct RoutedPersonaPromptRegistry: Sendable {
    public typealias Loader = @Sendable (_ fileName: String) -> Data?

    private let resources: [String: String]
    private let loader: Loader?

    /// Explicit sources carry their own checksums; the engine has no bundled character.
    public init(expectedChecksums: [String: String], loader: @escaping Loader) {
        self.resources = expectedChecksums
        self.loader = loader
    }

    public init() {
        resources = [:]
        loader = nil
    }

    public func load() throws -> RoutedPersonaPromptSet {
        guard loader != nil else { throw RoutedPersonaPromptRegistryError.notConfigured }
        let core = try text("persona_core.md")
        let cardsData = try verifiedData("scene_cards.json")
        guard
            let rawCards = try? JSONDecoder().decode(
                [String: PersonaSceneCard].self,
                from: cardsData
            ),
            Set(rawCards.keys) == Set(PersonaSceneRoute.allCases.map(\.rawValue))
        else {
            throw RoutedPersonaPromptRegistryError.invalidSceneCards
        }
        let cards = Dictionary(
            uniqueKeysWithValues: try rawCards.map { key, value in
                guard let route = PersonaSceneRoute(rawValue: key) else {
                    throw RoutedPersonaPromptRegistryError.invalidSceneCards
                }
                return (route, value)
            }
        )
        return RoutedPersonaPromptSet(
            core: core,
            sceneCards: cards
        )
    }

    private func text(_ fileName: String) throws -> String {
        let data = try verifiedData(fileName)
        guard let value = String(data: data, encoding: .utf8) else {
            throw RoutedPersonaPromptRegistryError.invalidUTF8(fileName)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func verifiedData(_ fileName: String) throws -> Data {
        guard let data = loader?(fileName) else {
            throw RoutedPersonaPromptRegistryError.resourceMissing(fileName)
        }
        let actual = Self.sha256(data)
        guard let expected = resources[fileName], actual == expected else {
            throw RoutedPersonaPromptRegistryError.checksumMismatch(
                resource: fileName,
                expected: resources[fileName] ?? "",
                actual: actual
            )
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

}
