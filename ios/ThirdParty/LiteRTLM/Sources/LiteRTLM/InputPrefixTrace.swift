/// Diagnostic overlap between submitted inputs, not a claim about physical KV
/// hits. Native state can also match generated tokens, which this trace omits.
struct InputPrefixTrace {
    private var previous: [Int32] = []
    func prepare(_ tokens: [Int32]) -> Int {
        zip(previous, tokens).prefix { $0 == $1 }.count
    }
    mutating func commit(_ tokens: [Int32]) { previous = tokens }
    mutating func invalidate() { previous = [] }
}
