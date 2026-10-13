import Foundation

/// Train-only character 2-gram TF-IDF, equivalent to query_gate/lexical.py.
struct ReactionQueryLexicalIndex: Sendable {
    private let idf: [String: Double]
    private let documents: [[String: Double]]

    init(examples: [String]) {
        let counts = examples.map { Self.grams($0) }
        var frequency: [String: Int] = [:]
        for row in counts {
            for gram in row.keys { frequency[gram, default: 0] += 1 }
        }
        let documentCount = Double(examples.count)
        let weights = frequency.mapValues { log((1 + documentCount) / (1 + Double($0))) + 1 }
        idf = weights
        documents = counts.map { Self.encode($0, idf: weights) }
    }

    func scores(_ text: String) -> [Double] {
        let query = Self.encode(Self.grams(text), idf: idf)
        return documents.map { document in
            query.reduce(0) { total, item in total + item.value * document[item.key, default: 0] }
        }
    }

    private static func grams(_ text: String) -> [String: Int] {
        let scalars = Array(text.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard scalars.count >= 2 else { return [:] }
        var counts: [String: Int] = [:]
        for index in 0..<(scalars.count - 1) {
            let gram = String(scalars[index]) + String(scalars[index + 1])
            counts[gram, default: 0] += 1
        }
        return counts
    }

    private static func encode(_ counts: [String: Int], idf: [String: Double]) -> [String: Double] {
        var values: [String: Double] = [:]
        for (gram, count) in counts {
            if let weight = idf[gram] { values[gram] = (1 + log(Double(count))) * weight }
        }
        let norm = sqrt(values.values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return values }
        return values.mapValues { $0 / norm }
    }
}

/// Only signals used by the frozen policy are computed at runtime.
struct ReactionQueryTextSignals: Sendable {
    let lengthLog: Double
    let acknowledgementOnly: Double
    let ellipsisOnly: Double
    let reference: Double
    let recall: Double
    let standaloneRequest: Double

    init(_ text: String) {
        let compact = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let length = compact.unicodeScalars.count
        lengthLog = log1p(Double(length)) / log(501)
        reference = Self.contains(#"그거|그게|그걸|그건|이거|이게|이걸|저거|그렇게|이렇게|저렇게|걔|그사람|그곳|그중|그때|아까그|방금그"#, in: compact)
        acknowledgementOnly = Self.matches(#"(ㅋ+|ㅎ+|ㅇ+|응+|어+|음+|아+|오+|오키|오케이|알겠어|알았어|그래|그러네|좋아|싫어|맞아|맞지|아니|아니야|됐어|괜찮아|웅+|넵|네|예)[.!?~ㅋㅎㅠㅜ ]*"#, in: compact)
        ellipsisOnly = Self.matches(#"(왜|어째서|어떻게|얼마|언제|어디|뭐|누가|어느거|무슨뜻|너는|넌|나는|난|그건|다른건|요즘은|진짜|정말)(요|인데|야|지|에|까지|부터|라고)?[?!~.]*"#, in: compact)
        recall = Self.contains(#"(아까|방금|전에).*(말|얘기|기억|했|한|하던)"#, in: compact)
        let separators = #"그건\s*그렇고|다른\s*얘긴데|그거\s*말고|아\s*맞다"#
        let expression = try! NSRegularExpression(pattern: separators)
        let last = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).last
        let tail = last.flatMap { Range($0.range, in: text).map { String(text[$0.upperBound...]) } } ?? text
        let compactTail = tail.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let target = #"저녁|점심|아침|메뉴|음식|영화|음악|노래|게임|취미|책|차|커피|산책|잠|날씨|별|꿈|일|친구|오늘|내일|가족|학교|공부|청소|운동|여행|돈|방|선물|약속|기분|몸|요리|배고|피곤|졸려|심심|춥|더워"#
        let request = #"추천|알려|해줘|해줄|설명|뭐먹|뭐마|어떤|무슨|좋아해|싫어해|고민|싶어|방법|이유|어때|궁금|배고|피곤|졸려|심심|춥|더워"#
        standaloneRequest = Self.contains(target, in: compactTail) * Self.contains(request, in: compactTail)
    }

    private static func contains(_ pattern: String, in text: String) -> Double {
        text.range(of: pattern, options: .regularExpression) == nil ? 0 : 1
    }

    private static func matches(_ pattern: String, in text: String) -> Double {
        contains("^(?:" + pattern + ")$", in: text)
    }
}
