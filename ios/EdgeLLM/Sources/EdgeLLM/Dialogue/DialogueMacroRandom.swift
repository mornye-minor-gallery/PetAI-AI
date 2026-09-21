import Foundation

/// cyrb53 + seedrandom ARC4, matching the pinned upstream pick handler's UTF-16 hash and seed.
enum DialogueMacroRandom {
    static func hash(_ value: String) -> UInt64 {
        var h1: UInt32 = 0xdeadbeef, h2: UInt32 = 0x41c6ce57
        for c in value.utf16 { h1 = (h1 ^ UInt32(c)) &* 2654435761; h2 = (h2 ^ UInt32(c)) &* 1597334677 }
        h1 = ((h1 ^ (h1 >> 16)) &* 2246822507) ^ ((h2 ^ (h2 >> 13)) &* 3266489909)
        h2 = ((h2 ^ (h2 >> 16)) &* 2246822507) ^ ((h1 ^ (h1 >> 13)) &* 3266489909)
        return (UInt64(h2 & 2097151) << 32) + UInt64(h1)
    }
    static func pick(chatID: String, original: String, offset: Int, reroll: String?) -> Double {
        var parts = [String(hash(chatID)),String(hash(original)),String(offset)]
        if let reroll, !reroll.isEmpty, reroll != "0" { parts.append(reroll) }
        let seed = String(hash(parts.joined(separator:"-")))
        var key: [Int] = [], smear = 0
        for (j,c) in seed.utf16.enumerated() {
            let i = j & 255
            if key.count <= i { key.append(contentsOf:repeatElement(0,count:i-key.count+1)) }
            smear ^= key[i] * 19
            key[i] = (smear + Int(c)) & 255
        }
        var s = Array(0...255), j = 0
        for i in 0..<256 { j = (j + s[i] + key[i % key.count]) & 255; s.swapAt(i,j) }
        var i = 0; j = 0
        func next() -> Int { i = (i+1)&255; j = (j+s[i])&255; s.swapAt(i,j); return s[(s[i]+s[j])&255] }
        for _ in 0..<256 { _ = next() }
        var n = 0.0, d = 281_474_976_710_656.0, x = 0.0
        for _ in 0..<6 { n = n*256 + Double(next()) }
        while n < 4_503_599_627_370_496 { n = (n+x)*256; d *= 256; x = Double(next()) }
        while n >= 9_007_199_254_740_992 { n /= 2; d /= 2; x = floor(x/2) }
        return (n+x)/d
    }
}

extension DialogueMacroEvaluator {
    mutating func dice(_ raw: String) throws -> String {
        let formula = Int(raw).map { "1d\($0)" } ?? raw
        let regex = try NSRegularExpression(pattern:#"^(\d*)d(\d+)([+-]\d+)?$"#,options:.caseInsensitive)
        let ns = formula as NSString
        guard let match = regex.firstMatch(in:formula,range:NSRange(location:0,length:ns.length)) else { throw WorldInfoTextError.invalidMacro("Invalid dice formula") }
        let rawCount = ns.substring(with:match.range(at:1))
        guard let count = Int(rawCount.isEmpty ? "1" : rawCount) else { throw WorldInfoTextError.invalidMacro("Invalid dice count") }
        let sides = Int(ns.substring(with:match.range(at:2))) ?? 0
        let bonusText = match.range(at:3).location == NSNotFound ? "0" : ns.substring(with:match.range(at:3))
        guard let bonus = Int(bonusText) else { throw WorldInfoTextError.invalidMacro("Invalid dice modifier") }
        guard (1...100_000).contains(count), (1...1_000_000).contains(sides) else { throw WorldInfoTextError.invalidMacro("Invalid dice bounds") }
        var total = bonus
        for _ in 0..<count {
            let addition = total.addingReportingOverflow(Int(try roll() * Double(sides))+1)
            guard !addition.overflow else { throw WorldInfoTextError.invalidMacro("Dice total overflows integer range") }
            total = addition.partialValue
        }
        return String(total)
    }
}
