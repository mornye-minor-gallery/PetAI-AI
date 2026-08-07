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
    public let sceneRouter: String
    public let sceneCards: [PersonaSceneRoute: PersonaSceneCard]

    public func card(scene: PersonaSceneRoute) -> String? {
        return sceneCards[scene]?.card
    }

    public func responseSystemPrompt(activeCard: String?) -> String {
        var sections = [core]
        if let activeCard,
           !activeCard.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty
        {
            sections.append(
                """
                ## 이번 응답의 활성 장면 카드
                \(activeCard) 다른 장면 규칙은 이번 응답에 사용하지 않는다.
                """
            )
        }
        sections.append(MemoryTaggedChatPrompt.wrappedAxesV1)
        return sections.joined(separator: "\n\n")
    }

}

public enum RoutedPersonaPromptRegistryError: Error, Equatable, Sendable {
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

    private static let resources: [String: String] = [
        "persona_core.md":
            "b649715757a44664b5b815c36e8db73237561018c0986479164a821da48abd53",
        "scene_router.md":
            "9a7a3220c80fdd5d7d0624a412e88e9b9aebc300241495127a67dd306b81964c",
        "scene_cards.json":
            "3fb0f4afed22b29299824d784ce1b70fb530020c4b7ad4f45615c8e206a6cbc0",
    ]

    private let loader: Loader

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public init() {
        loader = Self.bundleLoader
    }

    public func load() throws -> RoutedPersonaPromptSet {
        let core = try text("persona_core.md")
        let sceneRouter = try text("scene_router.md")
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
            sceneRouter: sceneRouter,
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
        guard let data = loader(fileName) else {
            throw RoutedPersonaPromptRegistryError.resourceMissing(fileName)
        }
        let actual = Self.sha256(data)
        guard let expected = Self.resources[fileName], actual == expected else {
            throw RoutedPersonaPromptRegistryError.checksumMismatch(
                resource: fileName,
                expected: Self.resources[fileName] ?? "",
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

    private static let bundleLoader: Loader = { fileName in
        let parts = fileName.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let resource = String(parts[0])
        let fileExtension = String(parts[1])

        #if SWIFT_PACKAGE
        let bundles = [Bundle.module]
        #else
        let bundles = [Bundle.main, Bundle(for: RoutedPersonaPromptBundleToken.self)]
        #endif

        for bundle in bundles {
            let candidates = [
                bundle.url(
                    forResource: resource,
                    withExtension: fileExtension,
                    subdirectory: "Prompts/RoutedPersona"
                ),
                bundle.url(
                    forResource: resource,
                    withExtension: fileExtension,
                    subdirectory: "EdgeLLMPrompts"
                ),
                bundle.url(forResource: resource, withExtension: fileExtension),
            ]
            if let url = candidates.compactMap({ $0 }).first,
               let data = try? Data(contentsOf: url)
            {
                return data
            }
        }
        return nil
    }
}

public struct RoutedPersonaRouteParser: Sendable {
    public init() {}

    public func scene(_ rawText: String) -> PersonaSceneRoute? {
        uniqueRoute(rawText, routes: PersonaSceneRoute.allCases)
    }

    private func uniqueRoute<Route: RawRepresentable>(
        _ rawText: String,
        routes: [Route]
    ) -> Route? where Route.RawValue == String {
        let uppercased = rawText.uppercased()
        let matches = routes.filter { route in
            uppercased.range(
                of: "(?<![A-Z0-9_])\(NSRegularExpression.escapedPattern(for: route.rawValue))(?![A-Z0-9_])",
                options: .regularExpression
            ) != nil
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

public struct RoutedPersonaSessionContext: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user = "사용자"
        case assistant = "캐릭터"
    }

    public struct Turn: Equatable, Sendable {
        public let role: Role
        public let text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    public let maximumTurnCount: Int
    public private(set) var turns: [Turn]

    public init(
        maximumTurnCount: Int = SLMConfiguration.production.persona
            .recentMessageLimit,
        turns: [Turn] = []
    ) {
        self.maximumTurnCount = max(0, maximumTurnCount)
        self.turns = Array(turns.suffix(max(0, maximumTurnCount)))
    }

    public mutating func appendExchange(
        userMessage: String,
        assistantMessage: String
    ) {
        append(.user, text: userMessage)
        append(.assistant, text: assistantMessage)
    }

    public mutating func removeAll() {
        turns.removeAll()
    }

    public func routerInput(currentUserMessage: String) -> String {
        renderedInput(
            currentSectionTitle: "마지막 사용자 요청",
            currentText: currentUserMessage
        )
    }

    public func responseInput(memoryAugmentedUserMessage: String) -> String {
        renderedInput(
            currentSectionTitle: "현재 사용자 입력과 회수 기억",
            currentText: memoryAugmentedUserMessage
        )
    }

    private mutating func append(_ role: Role, text: String) {
        let normalized = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty, maximumTurnCount > 0 else { return }
        turns.append(Turn(role: role, text: normalized))
        if turns.count > maximumTurnCount {
            turns.removeFirst(turns.count - maximumTurnCount)
        }
    }

    private func renderedInput(
        currentSectionTitle: String,
        currentText: String
    ) -> String {
        var sections: [String] = []
        if !turns.isEmpty {
            let history = turns.map { "\($0.role.rawValue): \($0.text)" }
                .joined(separator: "\n")
            sections.append("## 최근 대화\n\(history)")
        }
        sections.append(
            "## \(currentSectionTitle)\n" + currentText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
        return sections.joined(separator: "\n\n")
    }
}

private final class RoutedPersonaPromptBundleToken {}
