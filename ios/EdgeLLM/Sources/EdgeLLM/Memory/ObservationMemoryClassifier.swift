import CryptoKit
import Foundation

public enum ObservationMemoryClassifierError:
    Error,
    Equatable,
    Sendable
{
    case prototypeResourceMissing
    case unsupportedPrototypeSchema(Int)
    case emptyPrototypeGroup(String)
    case inconsistentEmbeddingDimension
}

extension ObservationMemoryClassifierError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .prototypeResourceMissing:
            "EdgeMem Korean classification prototypes are missing."
        case .unsupportedPrototypeSchema(let version):
            "Unsupported EdgeMem prototype schema \(version)."
        case .emptyPrototypeGroup(let group):
            "EdgeMem prototype group \(group) is empty."
        case .inconsistentEmbeddingDimension:
            "EdgeMem prototype embeddings have inconsistent dimensions."
        }
    }
}

public struct MemoryPrototypeSet: Equatable, Sendable {
    public let schemaVersion: Int
    public let preference: [String]
    public let event: [String]
    public let none: [String]
    public let sourceSHA256: String

    public init(
        schemaVersion: Int,
        preference: [String],
        event: [String],
        none: [String],
        sourceSHA256: String
    ) throws {
        guard schemaVersion == 1 else {
            throw ObservationMemoryClassifierError
                .unsupportedPrototypeSchema(schemaVersion)
        }
        guard !preference.isEmpty else {
            throw ObservationMemoryClassifierError
                .emptyPrototypeGroup("preference")
        }
        guard !event.isEmpty else {
            throw ObservationMemoryClassifierError
                .emptyPrototypeGroup("event")
        }
        guard !none.isEmpty else {
            throw ObservationMemoryClassifierError
                .emptyPrototypeGroup("none")
        }
        self.schemaVersion = schemaVersion
        self.preference = preference
        self.event = event
        self.none = none
        self.sourceSHA256 = sourceSHA256
    }

    public static func korean() throws -> MemoryPrototypeSet {
#if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
#else
        let resourceBundle = Bundle.main
#endif
        guard
            let url = resourceBundle.url(
                forResource: "prototypes.ko",
                withExtension: "json"
            )
        else {
            throw ObservationMemoryClassifierError.prototypeResourceMissing
        }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(PrototypePayload.self, from: data)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return try MemoryPrototypeSet(
            schemaVersion: decoded.schemaVersion,
            preference: decoded.preference,
            event: decoded.event,
            none: decoded.none,
            sourceSHA256: digest
        )
    }
}

private struct PrototypePayload: Decodable {
    let schemaVersion: Int
    let preference: [String]
    let event: [String]
    let none: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case preference
        case event
        case none
    }
}

public struct KoreanObservationRegexGate: Sendable {
    public static let version = "regex-ko-v1"

    private static let preferencePatterns = [
        NamedPattern("preference.like", #"좋아(?:하|해|했|졌|하는|해서|한다|함|더라|요)?"#),
        NamedPattern("preference.dislike", #"싫어(?:하|해|했|졌|하는|해서|한다|함|요)?"#),
        NamedPattern("preference.prefer", #"선호(?:하|해|했|하는|한다|함)?"#),
        NamedPattern("preference.favorite", #"최애|제일\s+좋|가장\s+좋"#),
        NamedPattern("preference.taste", #"취향|마음에\s+들|내\s*스타일"#),
        NamedPattern("preference.habit", #"즐겨|자주\s+(?:먹|듣|보|가|하)"#),
        NamedPattern("preference.avoid", #"못\s*(?:먹|마시|보|하)|피하(?:는|고|게|다)"#),
        NamedPattern("preference.comparison", #"보다\s+.+(?:이|가)?\s*(?:더|낫)"#),
    ]

    private static let eventPatterns = [
        NamedPattern("event.temporal", #"어제|오늘|내일|지난\s*(?:주|달|해)|다음\s*(?:주|달|해)|이번\s*(?:주|달)"#),
        NamedPattern("event.attend", #"다녀왔|참석했|방문했|갔다\s*왔|갔어|왔어"#),
        NamedPattern("event.social", #"만났|약속했|모였|헤어졌"#),
        NamedPattern("event.schedule", #"예약했|예약이|예정이|계획이|약속이"#),
        NamedPattern("event.cancel", #"취소했|미뤘|연기했"#),
        NamedPattern("event.progress", #"시작했|끝냈|완료했|마쳤|수료했"#),
        NamedPattern("event.outcome", #"합격했|붙었|떨어졌|성공했|실패했"#),
        NamedPattern("event.purchase", #"샀어|구매했|주문했"#),
    ]

    private static let hardIgnorePattern = NamedPattern(
        "hard-ignore",
        #"^(?:안녕|하이|ㅎㅇ|네|넵|응|ㅇㅇ|그래|그렇구나|알겠어|고마워|감사|ㅋㅋ+|ㅎㅎ+|[!?.,~ㅋㅎㅠㅜᄏ휴ᅮ]+)$"#,
        options: [.caseInsensitive]
    )

    public init() {}

    public func evaluate(_ text: String) -> MemoryRegexGateResult {
        let normalized = Self.normalize(text)
        guard
            !normalized.isEmpty,
            !Self.hardIgnorePattern.matchesEntire(normalized)
        else {
            return MemoryRegexGateResult(
                preferenceHit: false,
                eventHit: false,
                hardIgnore: true
            )
        }

        var matchedPatterns: [String] = []
        var preferenceHit = false
        var eventHit = false

        for pattern in Self.preferencePatterns where pattern.matches(normalized) {
            matchedPatterns.append(pattern.name)
            preferenceHit = true
        }
        for pattern in Self.eventPatterns where pattern.matches(normalized) {
            matchedPatterns.append(pattern.name)
            if pattern.name != "event.temporal" {
                eventHit = true
            }
        }

        return MemoryRegexGateResult(
            preferenceHit: preferenceHit,
            eventHit: eventHit,
            matchedPatterns: matchedPatterns
        )
    }

    private static func normalize(_ text: String) -> String {
        text
            .precomposedStringWithCompatibilityMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

public actor RegexPrototypeObservationClassifier:
    MemoryObservationClassifying
{
    public nonisolated let version: String

    private let regex = KoreanObservationRegexGate()
    private let embedder: any ClassificationEmbeddingProviding
    private let prototypes: MemoryPrototypeSet
    private let preferenceThreshold: Float
    private let eventThreshold: Float
    private var cachedCentroids: PrototypeCentroids?

    public init(
        embedder: any ClassificationEmbeddingProviding,
        prototypes: MemoryPrototypeSet,
        preferenceThreshold: Float = 0.08,
        eventThreshold: Float = 0.08
    ) {
        self.embedder = embedder
        self.prototypes = prototypes
        self.preferenceThreshold = preferenceThreshold
        self.eventThreshold = eventThreshold
        version =
            "\(KoreanObservationRegexGate.version)+prototype-centroid-v1:"
            + String(prototypes.sourceSHA256.prefix(12))
    }

    public func evaluate(
        _ text: String
    ) async throws -> MemoryGateDecision {
        let regexResult = regex.evaluate(text)
        if regexResult.hardIgnore {
            return decision(
                label: .none,
                regex: regexResult,
                preferenceScore: nil,
                eventScore: nil
            )
        }

        let centroids = try await centroids()
        let vector = try await embedder.embedClassification(text)
        let noneSimilarity = try EmbeddingVectorMath.cosineSimilarity(
            vector,
            centroids.none
        )
        let preferenceScore =
            try EmbeddingVectorMath.cosineSimilarity(
                vector,
                centroids.preference
            ) - noneSimilarity
        let eventScore =
            try EmbeddingVectorMath.cosineSimilarity(
                vector,
                centroids.event
            ) - noneSimilarity

        let preference =
            regexResult.preferenceHit
            || preferenceScore >= preferenceThreshold
        let event =
            regexResult.eventHit
            || eventScore >= eventThreshold
        let label: MemoryGateLabel
        if preference, event {
            label = .both
        } else if preference {
            label = .preference
        } else if event {
            label = .event
        } else {
            label = .none
        }

        return decision(
            label: label,
            regex: regexResult,
            preferenceScore: preferenceScore,
            eventScore: eventScore
        )
    }

    private func centroids() async throws -> PrototypeCentroids {
        if let cachedCentroids {
            return cachedCentroids
        }
        let preference = try await centroid(for: prototypes.preference)
        let event = try await centroid(for: prototypes.event)
        let none = try await centroid(for: prototypes.none)
        let result = PrototypeCentroids(
            preference: preference,
            event: event,
            none: none
        )
        cachedCentroids = result
        return result
    }

    private func centroid(for texts: [String]) async throws -> [Float] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            vectors.append(
                try await embedder.embedClassification(text)
            )
        }
        guard
            let dimension = vectors.first?.count,
            dimension == embedder.dimension,
            vectors.allSatisfy({ $0.count == dimension })
        else {
            throw ObservationMemoryClassifierError
                .inconsistentEmbeddingDimension
        }

        var mean = [Float](repeating: 0, count: dimension)
        for vector in vectors {
            for index in vector.indices {
                mean[index] += vector[index] / Float(vectors.count)
            }
        }
        let magnitude = sqrt(
            mean.reduce(Float.zero) { $0 + ($1 * $1) }
        )
        guard magnitude > 0, magnitude.isFinite else {
            throw ObservationMemoryClassifierError
                .inconsistentEmbeddingDimension
        }
        return mean.map { $0 / magnitude }
    }

    private func decision(
        label: MemoryGateLabel,
        regex: MemoryRegexGateResult,
        preferenceScore: Float?,
        eventScore: Float?
    ) -> MemoryGateDecision {
        MemoryGateDecision(
            label: label,
            regex: regex,
            preferenceScore: preferenceScore,
            eventScore: eventScore,
            preferenceThreshold: preferenceThreshold,
            eventThreshold: eventThreshold,
            classifierVersion: version,
            embeddingModelID: embedder.modelID
        )
    }
}

private struct PrototypeCentroids {
    let preference: [Float]
    let event: [Float]
    let none: [Float]
}

private struct NamedPattern: @unchecked Sendable {
    let name: String
    private let expression: NSRegularExpression

    init(
        _ name: String,
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) {
        self.name = name
        expression = try! NSRegularExpression(
            pattern: pattern,
            options: options
        )
    }

    func matches(_ text: String) -> Bool {
        expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
    }

    func matchesEntire(_ text: String) -> Bool {
        guard
            let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            )
        else {
            return false
        }
        return match.range == NSRange(text.startIndex..., in: text)
    }
}
