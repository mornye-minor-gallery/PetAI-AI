import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}
// Chunk boundaries can split any marker; no internal thought text may escape.
let raw = "<|channel>thought\n비공개 생각<channel|>안녕!"
for width in 1...raw.count {
    var filter = GemmaChannelFilter()
    var rest = raw[...]
    var output = ""
    while !rest.isEmpty {
        let end = rest.index(rest.startIndex, offsetBy: min(width, rest.count))
        output += filter.append(String(rest[..<end])); rest = rest[end...]
    }
    output += filter.finish()
    expect(output == "안녕!", "thought leak or lost output at width \(width): \(output)")
}
var open = GemmaChannelFilter(prefill: "<|turn>model\n<|channel>thought\n")
expect(open.append("숨긴 내용<channel|>응") + open.finish() == "응", "open prefill channel")
var literal = GemmaChannelFilter()
expect(literal.append("a < b") + literal.finish() == "a < b", "literal less-than")
var incomplete = GemmaChannelFilter()
expect(incomplete.append("<|channel>thought\n비밀") + incomplete.finish() == "", "unfinished thought")
var prefix = InputPrefixTrace()
expect(prefix.prepare([1,2,3]) == 0, "cold prefix")
prefix.commit([1,2,3])
expect(prefix.prepare([1,2,4]) == 2, "changed suffix")
expect(prefix.prepare([1,2]) == 2, "shorter input")
prefix.invalidate()
expect(prefix.prepare([1,2,3]) == 0, "failed generation invalidates trace")
print("cached session state tests passed")
