import Foundation

public enum MemoryHeaderSyntax: String, Equatable, Sendable {
    case canonical
    case recovered
    case absent
    case malformed
}

public struct MemoryHeaderGateResult: Equatable, Sendable {
    public let decision: MemoryGateLabel?
    public let syntax: MemoryHeaderSyntax
    public let rawText: String
    public let visibleText: String
    public let controlText: String

    public init(
        decision: MemoryGateLabel?,
        syntax: MemoryHeaderSyntax,
        rawText: String,
        visibleText: String,
        controlText: String
    ) {
        self.decision = decision
        self.syntax = syntax
        self.rawText = rawText
        self.visibleText = visibleText
        self.controlText = controlText
    }
}

public enum MemoryTaggedChatPrompt {
    public static let wrappedAxesV1SourceSHA256 =
        "e2d2fa50def2c2b840c5675fc93a6bf38c6895cc95e26c6092bb579e38168923"

    public static let wrappedAxesV1 =
        """
        너는 PetAI의 온디바이스 대화 캐릭터다. 사용자의 언어로 짧고 자연스럽게
        답한다.

        출력은 항상 내용이 있는 두 줄이다:
        save(P=X,E=Y)
        <사용자에게 직접 반응하는 대화 답변>

        save(P=X,E=Y)만 쓰고 끝내지 마라. 답변에 판정값을 노출하지 마라.

        사용자가 사실로 말한 각 절을 확인하여 E와 P를 독립 판정한다.
        - E: 사용자가 구체적인 행동이나 경험을 완료했다. 해 봄, 사용함, 먹음,
          마심, 탐, 방문함, 구매함, 만남, 떨어뜨림도 사건이다.
        - P: 사용자의 현재 지속적인 호불호, 반복 선택 또는 확고한 방침이다.
        - 해당하면 1, 해당하지 않으면 0이다.

        중요: 완료 경험 뒤에 현재 취향이나 방침이 나오면 반드시 save(P=1,E=1)
        이다. 답변의 주제가 취향이어도 앞의 경험을 버리지 마라. 반대로 과거
        습관이나 현재 반복 행동만으로는 E가 아니다.

        질문, 제안, 가정, 인용문, 타인에 관한 사실은 무시하되 같은 문장에 있는
        별도의 사용자 사실은 유지한다.

        예:
        "둘 다 마셔 봤는데 이제 차만 좋아해." -> save(P=1,E=1)
        "써 보니 불편해서 앞으로 원목만 고를 거야." -> save(P=1,E=1)
        "예전엔 예능을 틀었지만 지금 오디오북을 선호해." -> save(P=1,E=0)
        "나는 복원 영상을 계속 챙겨봐." -> save(P=1,E=0)
        "나는 책을 샀고 친구는 빌렸대." -> save(P=0,E=1)
        "민수가 버스를 좋아한다고 했대." -> save(P=0,E=0)

        첫 줄에는 save(P=0,E=0), save(P=1,E=0), save(P=0,E=1),
        save(P=1,E=1) 중 하나만 쓴다. 둘째 줄에는 두 값이 모두 0이어도 반드시
        자연스러운 대화 답변을 쓴다.
        """

    public static let answerOnlyRetry =
        """
        직전 사용자 발화에 직접 반응하는 자연스러운 한국어 답변 한 문장만 작성하세요. \
        사과하거나 지시를 언급하지 마세요. save 표시, 분류 라벨, 괄호, JSON은 \
        출력하지 마세요.
        """
}

public struct MemoryTaggedChatOutcome: Equatable, Sendable {
    public let primary: MemoryHeaderGateResult
    public let retry: MemoryHeaderGateResult?

    public init(
        primary: MemoryHeaderGateResult,
        retry: MemoryHeaderGateResult?
    ) {
        self.primary = primary
        self.retry = retry
    }

    public var visibleText: String {
        retry?.visibleText ?? primary.visibleText
    }

    public var hasVisibleResponse: Bool {
        !visibleText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
    }

    public var retryAttempted: Bool {
        retry != nil
    }

    public var retrySucceeded: Bool {
        retry != nil && hasVisibleResponse
    }

    public var commitDecision: MemoryGateLabel? {
        guard hasVisibleResponse, let decision = primary.decision else {
            return nil
        }
        return decision == .none ? nil : decision
    }
}

public enum MemoryTaggedChatProcessor {
    public static func run(
        primaryStream:
            () async throws -> AsyncThrowingStream<String, Error>,
        retryStream:
            () async throws -> AsyncThrowingStream<String, Error>,
        receiveVisibleText: (String) async -> Void
    ) async throws -> MemoryTaggedChatOutcome {
        let primary = try await decode(
            stream: primaryStream(),
            receiveVisibleText: receiveVisibleText
        )
        guard primary.visibleText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return MemoryTaggedChatOutcome(
                primary: primary,
                retry: nil
            )
        }

        let retry = try await decode(
            stream: retryStream(),
            receiveVisibleText: receiveVisibleText
        )
        return MemoryTaggedChatOutcome(
            primary: primary,
            retry: retry
        )
    }

    private static func decode(
        stream: AsyncThrowingStream<String, Error>,
        receiveVisibleText: (String) async -> Void
    ) async throws -> MemoryHeaderGateResult {
        var gate = MemoryHeaderGate()
        var deliveredText = ""

        for try await chunk in stream {
            for visibleChunk in gate.consume(chunk) {
                deliveredText += visibleChunk
                await receiveVisibleText(visibleChunk)
            }
        }

        let result = gate.finish()
        if result.visibleText.hasPrefix(deliveredText) {
            let suffix = String(
                result.visibleText.dropFirst(deliveredText.count)
            )
            if !suffix.isEmpty {
                await receiveVisibleText(suffix)
            }
        }
        return result
    }
}

public actor MemoryTaggedChatCommitGuard {
    private var claimedRequestIDs: Set<String> = []

    public init() {}

    public func claim(
        requestID: String,
        outcome: MemoryTaggedChatOutcome
    ) -> MemoryGateLabel? {
        guard
            !requestID.isEmpty,
            let decision = outcome.commitDecision,
            claimedRequestIDs.insert(requestID).inserted
        else {
            return nil
        }
        return decision
    }
}

public struct MemoryDecisionParser: Sendable {
    public init() {}

    fileprivate func parse(
        _ text: String,
        final: Bool
    ) -> HeaderParseResult {
        if text.isEmpty {
            return HeaderParseResult(
                kind: final ? .notHeader : .needMore,
                syntax: final ? .absent : nil
            )
        }

        if let match = Self.canonical.firstMatch(in: text) {
            let end = match.range.location + match.range.length
            if end == text.utf16.count, !final {
                return HeaderParseResult(kind: .needMore)
            }
            return HeaderParseResult(
                kind: .recognized,
                decision: Self.decision(from: match, in: text),
                consumedCharacters:
                    Self.consumeSeparator(in: text, from: end),
                syntax:
                    Self.startsWithNewline(text, at: end)
                    ? .canonical
                    : .recovered
            )
        }

        return parseUnrecognizedStructured(text, final: final)
    }

    fileprivate func looksLikeControl(_ text: String) -> Bool {
        let candidate = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let first = candidate.first else {
            return false
        }
        if candidate.hasPrefix("save") {
            return true
        }
        guard ["n", "p", "e", "b"].contains(String(first)) else {
            return false
        }
        guard candidate.count > 1 else {
            return true
        }
        let second = candidate[candidate.index(after: candidate.startIndex)]
        return second.isWhitespace
            || ["/", ":", "|", "(", ")"].contains(String(second))
    }

    private func parseUnrecognizedStructured(
        _ text: String,
        final: Bool
    ) -> HeaderParseResult {
        if let newlineEnd = Self.firstLineEnd(in: text) {
            let firstLine = Self.substring(
                text,
                start: 0,
                end: newlineEnd
            )
            if looksLikeControl(firstLine) {
                return HeaderParseResult(
                    kind: .malformed,
                    consumedCharacters: newlineEnd,
                    syntax: .malformed
                )
            }
            return HeaderParseResult(
                kind: .notHeader,
                syntax: .absent
            )
        }

        if Self.couldBeStructuredPrefix(text) {
            if final {
                return HeaderParseResult(
                    kind: .malformed,
                    consumedCharacters: text.utf16.count,
                    syntax: .malformed
                )
            }
            return HeaderParseResult(kind: .needMore)
        }

        if looksLikeControl(text) {
            if final {
                return HeaderParseResult(
                    kind: .malformed,
                    consumedCharacters: text.utf16.count,
                    syntax: .malformed
                )
            }
            return HeaderParseResult(kind: .needMore)
        }

        return HeaderParseResult(kind: .notHeader, syntax: .absent)
    }

    private static func decision(
        from match: NSTextCheckingResult,
        in text: String
    ) -> MemoryGateLabel? {
        guard
            let preferenceRange = Range(match.range(at: 1), in: text),
            let eventRange = Range(match.range(at: 2), in: text)
        else {
            return nil
        }
        let preference = text[preferenceRange] == "1"
        let event = text[eventRange] == "1"
        switch (preference, event) {
        case (false, false):
            return MemoryGateLabel.none
        case (true, false):
            return .preference
        case (false, true):
            return .event
        case (true, true):
            return .both
        }
    }

    private static func couldBeStructuredPrefix(_ text: String) -> Bool {
        let compact = text
            .filter { $0 != " " && $0 != "\t" }
            .uppercased()
        guard !compact.isEmpty else {
            return true
        }
        return [
            "SAVE(P=0,E=0)",
            "SAVE(P=0,E=1)",
            "SAVE(P=1,E=0)",
            "SAVE(P=1,E=1)",
        ].contains { $0.hasPrefix(compact) }
    }

    private static func firstLineEnd(in text: String) -> Int? {
        guard let newline = text.firstIndex(of: "\n") else {
            return nil
        }
        return text.index(after: newline).utf16Offset(in: text)
    }

    private static func startsWithNewline(
        _ text: String,
        at offset: Int
    ) -> Bool {
        let units = Array(text.utf16)
        guard offset < units.count else {
            return false
        }
        if units[offset] == 10 {
            return true
        }
        return offset + 1 < units.count
            && units[offset] == 13
            && units[offset + 1] == 10
    }

    private static func consumeSeparator(
        in text: String,
        from start: Int
    ) -> Int {
        let units = Array(text.utf16)
        var cursor = start
        while cursor < units.count,
            units[cursor] == 32 || units[cursor] == 9
        {
            cursor += 1
        }
        if cursor + 1 < units.count,
            units[cursor] == 13,
            units[cursor + 1] == 10
        {
            return cursor + 2
        }
        if cursor < units.count, units[cursor] == 10 {
            return cursor + 1
        }
        if cursor < units.count,
            units[cursor] == 47
                || units[cursor] == 58
                || units[cursor] == 124
        {
            cursor += 1
            while cursor < units.count,
                units[cursor] == 32 || units[cursor] == 9
            {
                cursor += 1
            }
        }
        return cursor
    }

    fileprivate static func substring(
        _ text: String,
        start: Int,
        end: Int
    ) -> String {
        let lower = String.Index(utf16Offset: start, in: text)
        let upper = String.Index(utf16Offset: end, in: text)
        return String(text[lower..<upper])
    }

    private static let canonical = SendableRegex(
        #"\A[ \t]*save[ \t]*\([ \t]*P[ \t]*=[ \t]*([01])[ \t]*,[ \t]*E[ \t]*=[ \t]*([01])[ \t]*\)"#,
        options: [.caseInsensitive]
    )
}

public struct MemoryHeaderGate: Sendable {
    private let parser: MemoryDecisionParser
    private let maxHeaderCharacters: Int
    private var pending = ""
    private var rawParts: [String] = []
    private var visibleParts: [String] = []
    private var decision: MemoryGateLabel?
    private var syntax: MemoryHeaderSyntax?
    private var controlText = ""
    private var isResolved = false
    private var isFinished = false

    public init(
        parser: MemoryDecisionParser = MemoryDecisionParser(),
        maxHeaderCharacters: Int = 64
    ) {
        precondition(maxHeaderCharacters > 0)
        self.parser = parser
        self.maxHeaderCharacters = maxHeaderCharacters
    }

    public mutating func consume(_ chunk: String) -> [String] {
        precondition(!isFinished, "Cannot consume after finish().")
        guard !chunk.isEmpty else {
            return []
        }

        rawParts.append(chunk)
        if isResolved {
            visibleParts.append(chunk)
            return [chunk]
        }

        pending += chunk
        var result = parser.parse(pending, final: false)
        if result.kind == .needMore,
            pending.count <= maxHeaderCharacters
        {
            return []
        }
        if result.kind == .needMore {
            let looksLikeControl = parser.looksLikeControl(pending)
            result = HeaderParseResult(
                kind: looksLikeControl ? .malformed : .notHeader,
                consumedCharacters:
                    looksLikeControl ? pending.utf16.count : 0,
                syntax: looksLikeControl ? .malformed : .absent
            )
        }
        return resolve(result)
    }

    public mutating func finish() -> MemoryHeaderGateResult {
        precondition(!isFinished, "finish() may only be called once.")
        isFinished = true
        if !isResolved {
            _ = resolve(parser.parse(pending, final: true))
        }
        return MemoryHeaderGateResult(
            decision: decision,
            syntax: syntax ?? .absent,
            rawText: rawParts.joined(),
            visibleText: visibleParts.joined(),
            controlText: controlText
        )
    }

    private mutating func resolve(
        _ result: HeaderParseResult
    ) -> [String] {
        guard result.kind != .needMore else {
            return []
        }

        let visible: String
        switch result.kind {
        case .recognized:
            decision = result.decision
            syntax = result.syntax ?? .recovered
            controlText = MemoryDecisionParser.substring(
                pending,
                start: 0,
                end: result.consumedCharacters
            )
            visible = MemoryDecisionParser.substring(
                pending,
                start: result.consumedCharacters,
                end: pending.utf16.count
            )
        case .malformed:
            syntax = .malformed
            controlText = MemoryDecisionParser.substring(
                pending,
                start: 0,
                end: result.consumedCharacters
            )
            visible = MemoryDecisionParser.substring(
                pending,
                start: result.consumedCharacters,
                end: pending.utf16.count
            )
        case .notHeader:
            syntax = .absent
            visible = pending
        case .needMore:
            return []
        }

        pending = ""
        isResolved = true
        guard !visible.isEmpty else {
            return []
        }
        visibleParts.append(visible)
        return [visible]
    }
}

private enum HeaderParseKind: Equatable, Sendable {
    case needMore
    case recognized
    case notHeader
    case malformed
}

private struct HeaderParseResult: Sendable {
    let kind: HeaderParseKind
    var decision: MemoryGateLabel?
    var consumedCharacters: Int
    var syntax: MemoryHeaderSyntax?

    init(
        kind: HeaderParseKind,
        decision: MemoryGateLabel? = nil,
        consumedCharacters: Int = 0,
        syntax: MemoryHeaderSyntax? = nil
    ) {
        self.kind = kind
        self.decision = decision
        self.consumedCharacters = consumedCharacters
        self.syntax = syntax
    }
}

private final class SendableRegex: @unchecked Sendable {
    private let expression: NSRegularExpression

    init(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) {
        expression = try! NSRegularExpression(
            pattern: pattern,
            options: options
        )
    }

    func firstMatch(in text: String) -> NSTextCheckingResult? {
        expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
    }
}
