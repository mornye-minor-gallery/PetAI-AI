import CryptoKit
import Foundation

public enum AsterBoundaryRoute: String, Equatable, Sendable {
    case boundary = "BOUNDARY"
    case inScope = "IN_SCOPE"
}

public enum AsterSceneRoute: String, CaseIterable, Equatable, Sendable {
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

public struct AsterSceneCard: Codable, Equatable, Sendable {
    public let facetID: String?
    public let card: String?

    enum CodingKeys: String, CodingKey {
        case facetID = "facet_id"
        case card
    }
}

public struct AsterV14PromptSet: Equatable, Sendable {
    public let core: String
    public let boundaryRouter: String
    public let boundaryCard: String
    public let sceneRouter: String
    public let sceneCards: [AsterSceneRoute: AsterSceneCard]

    public func card(
        boundary: AsterBoundaryRoute,
        scene: AsterSceneRoute
    ) -> String? {
        if boundary == .boundary {
            return boundaryCard
        }
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

    public func responseUserMessage(
        boundary: AsterBoundaryRoute,
        userMessage: String,
        memoryAugmentedUserMessage: String
    ) -> String {
        boundary == .boundary
            ? userMessage
            : memoryAugmentedUserMessage
    }
}

public enum AsterV14PromptRegistryError: Error, Equatable, Sendable {
    case resourceMissing(String)
    case invalidUTF8(String)
    case checksumMismatch(
        resource: String,
        expected: String,
        actual: String
    )
    case invalidSceneCards
}

public struct AsterV14PromptRegistry: Sendable {
    public typealias Loader = @Sendable (_ fileName: String) -> Data?

    private static let resources: [String: String] = [
        "aster_v14_core.md":
            "287bf989eebcbba8c8aea02741093b2102a6e594eb98ed633a33c9b18e6f3c11",
        "aster_boundary_router.md":
            "35743a4c389232ef5515ee17fce838f31f6841bbf2afe78bdaace8f86fba63e2",
        "aster_boundary_card.md":
            "790b77d78a8c301a19cff0cbc1cfe019299b504ebe0eff2cd7c29c03d7007d6e",
        "aster_scene_router.md":
            "6115a85a002ee774617dd31f63972f43878b6477943cf5abe95e3d31d73247fc",
        "aster_scene_cards.json":
            "fa71ffbb3ad4c4a460511c439bf19b751f110b47077a0a9a48f92856c9b9e637",
    ]

    private let loader: Loader

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public init() {
        loader = Self.bundleLoader
    }

    public func load() throws -> AsterV14PromptSet {
        let core = try text("aster_v14_core.md")
        let boundaryRouter = try text("aster_boundary_router.md")
        let boundaryCard = try text("aster_boundary_card.md")
        let sceneRouter = try text("aster_scene_router.md")
        let cardsData = try verifiedData("aster_scene_cards.json")
        guard
            let rawCards = try? JSONDecoder().decode(
                [String: AsterSceneCard].self,
                from: cardsData
            ),
            Set(rawCards.keys) == Set(AsterSceneRoute.allCases.map(\.rawValue))
        else {
            throw AsterV14PromptRegistryError.invalidSceneCards
        }
        let cards = Dictionary(
            uniqueKeysWithValues: try rawCards.map { key, value in
                guard let route = AsterSceneRoute(rawValue: key) else {
                    throw AsterV14PromptRegistryError.invalidSceneCards
                }
                return (route, value)
            }
        )
        return AsterV14PromptSet(
            core: core,
            boundaryRouter: boundaryRouter,
            boundaryCard: boundaryCard,
            sceneRouter: sceneRouter,
            sceneCards: cards
        )
    }

    private func text(_ fileName: String) throws -> String {
        let data = try verifiedData(fileName)
        guard let value = String(data: data, encoding: .utf8) else {
            throw AsterV14PromptRegistryError.invalidUTF8(fileName)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func verifiedData(_ fileName: String) throws -> Data {
        guard let data = loader(fileName) else {
            throw AsterV14PromptRegistryError.resourceMissing(fileName)
        }
        let actual = Self.sha256(data)
        guard let expected = Self.resources[fileName], actual == expected else {
            throw AsterV14PromptRegistryError.checksumMismatch(
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
        let bundles = [Bundle.main, Bundle(for: AsterV14PromptBundleToken.self)]
        #endif

        for bundle in bundles {
            let candidates = [
                bundle.url(
                    forResource: resource,
                    withExtension: fileExtension,
                    subdirectory: "Prompts/AsterV14"
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

public struct AsterV14RouteParser: Sendable {
    public init() {}

    public func boundary(_ rawText: String) -> AsterBoundaryRoute? {
        uniqueRoute(
            rawText,
            routes: [AsterBoundaryRoute.boundary, .inScope]
        )
    }

    public func boundaryOrSafeFallback(
        _ rawText: String
    ) -> AsterBoundaryRoute {
        boundary(rawText) ?? .boundary
    }

    public func scene(_ rawText: String) -> AsterSceneRoute? {
        uniqueRoute(rawText, routes: AsterSceneRoute.allCases)
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

public struct AsterV14SessionContext: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user = "사용자"
        case assistant = "아스테르"
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

    public init(maximumTurnCount: Int = 6, turns: [Turn] = []) {
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

private final class AsterV14PromptBundleToken {}
