import Foundation
import Testing
@testable import EdgeLLM

@Test func worldInfoTextReplacementExpandsOnlyEachMatchedReplacement() throws {
    var context = WorldInfoTextContext(user: "Mina", localVariables: ["n": "0"])
    #expect(try WorldInfoText.replace("{{unknown}} cat cat", pattern: "/cat/g",
        replacement: "{{user}}-{{incvar::n}}", context: &context) == "{{unknown}} Mina-1 Mina-2")
    #expect(context.localVariables["n"] == "2")
    #expect(try WorldInfoText.replace("{{user}}", pattern: "/cat/",
        replacement: "{{incvar::n}}{{unsupported}}", context: &context) == "{{user}}")
    #expect(context.localVariables["n"] == "2")
    #expect(try WorldInfoText.replace("cat", pattern: "/[/",
        replacement: "{{incvar::n}}", context: &context) == "cat")
    #expect(context.localVariables["n"] == "2")
    #expect(try WorldInfoText.replace("cat", pattern: "/(cat)/",
        replacement: "$1-{{match}}-{{user}}", context: &context) == "cat-cat-Mina")
}

@Test func worldInfoTextReplacementRollsBackEarlierMatchesOnLaterFailure() throws {
    var context = WorldInfoTextContext(randomRolls: [0.9])
    let original = context
    #expect(throws: WorldInfoTextError.randomSourceExhausted) {
        try WorldInfoText.replace("x x", pattern: "/x/g",
            replacement: "{{incvar::n}}{{random::a::b}}", context: &context)
    }
    #expect(context == original)
    // An unknown macro introduced by a capture is subject to replacement expansion too.
    #expect(throws: WorldInfoTextError.self) {
        try WorldInfoText.replace("{{unsupported}}", pattern: "/(.+)/", replacement: "$1", context: &context)
    }
    #expect(context == original)
}

@Test func worldInfoTextKeyRegexPreservesUpstreamParsingAndJavaScriptSemantics() throws {
    #expect(try WorldInfoText.matchesRegex("/cat/i", text: "CAT") == true)
    #expect(try WorldInfoText.matchesRegex("/(?<=a)(?<part>b)/u", text: "ab") == true)
    #expect(try WorldInfoText.matchesRegex("/^.$/u", text: "😀") == true)
    #expect(try WorldInfoText.matchesRegex("/a/y", text: "ba") == false)
    for key in ["cat", "//", "/a/d", "/[/", "/a/ii", "/a/b/"] {
        #expect(try WorldInfoText.matchesRegex(key, text: key) == nil)
    }
    #expect(try WorldInfoText.matchesRegex(#"/a\/b/g"#, text: "a/b") == true)
    // A fresh regex must not retain global/sticky lastIndex between calls.
    #expect(try WorldInfoText.matchesRegex("/a/g", text: "a") == true)
    #expect(try WorldInfoText.matchesRegex("/a/g", text: "a") == true)
}

@Test func worldInfoTextReplacementUsesUpstreamCaptureSyntax() throws {
    #expect(try WorldInfoText.replace("ab ab", pattern: "/(?<first>a)(b)/g",
        replacement: "[$0/$1/$<first>/{{match}}/$9]") == "[ab/a/a/ab/] [ab/a/a/ab/]")
    #expect(try WorldInfoText.replace("cat", pattern: "cat", replacement: "dog") == "dog")
    // Unlike native JavaScript replacement strings, upstream only expands numbered/named captures.
    #expect(try WorldInfoText.replace("cat", pattern: "/cat/", replacement: "$&") == "$&")
    #expect(try WorldInfoText.replace("cat", pattern: "/[/", replacement: "dog") == "cat")
}

@Test func worldInfoTextMacrosUseExplicitContextAndLexicalOrder() throws {
    var context = WorldInfoTextContext(user: "Mina", char: "Momo", description: "{{char}} is kind",
        personality: "kind", scenario: "home", persona: "friend",
        localVariables: ["n": "2"], globalVariables: ["n": "8"], outlets: ["room": "warm"])
    let text = try WorldInfoText.expand("{{description}}/{{user}}/{{persona}}/{{outlet::room}}", context: &context)
    #expect(text == "{{char}} is kind/Mina/friend/warm")
    // The pinned default engine evaluates in lexical order; returned field values are not recursively expanded.
    #expect(try WorldInfoText.expand("{{getvar::x}}{{setvar::x::4}}{{incvar::n}}{{getglobalvar::n}}", context: &context) == "38")
    #expect(context.localVariables["x"] == "4")
    #expect(context.localVariables["n"] == "3")
    #expect(try WorldInfoText.expand("{{addvar::x::2}}{{decvar::x}}{{getvar::x}}", context: &context) == "55")
    #expect(try WorldInfoText.expand("{{setglobalvar::x::1}}{{incglobalvar::x}}{{getglobalvar::x}}", context: &context) == "22")
}

@Test func worldInfoTextVariableArithmeticPreservesJavaScriptConversion() throws {
    var context = WorldInfoTextContext(localVariables: ["n": "0x10", "s": "cat"])
    #expect(try WorldInfoText.expand("{{getvar::n}}/{{addvar::s::fish}}{{getvar::s}}/{{getvar::missing}}", context: &context) == "16/catfish/")
    #expect(try WorldInfoText.expand("{{incvar::s}}", context: &context) == "catfish1")
}

@Test func worldInfoTextRandomnessAndPickStateAreExplicitAndCodable() throws {
    var context = WorldInfoTextContext(randomRolls: [0.75, 0.1, 0.9])
    #expect(try WorldInfoText.expand("{{random::a::b}}", context: &context) == "b")
    let pick = "{{pick::a::b}}"
    #expect(try WorldInfoText.expand(pick, context: &context) == "b")
    #expect(try WorldInfoText.expand(pick, context: &context) == "b")
    #expect(context.randomIndex == 1)
    #expect(try JSONDecoder().decode(WorldInfoTextContext.self, from: JSONEncoder().encode(context)) == context)
    #expect(try WorldInfoText.expand("{{random::a::b}}", context: &context) == "a")
    #expect(try WorldInfoText.expand("{{random::a::b}}", context: &context) == "b")
    #expect(throws: WorldInfoTextError.randomSourceExhausted) {
        try WorldInfoText.expand("{{random::a::b}}", context: &context)
    }
}

@Test func worldInfoTextRejectsUnsupportedMacrosAndDoesNotPartiallyCommitState() throws {
    var context = WorldInfoTextContext()
    for text in ["{{unknown}}", "{{date}}", "{{space::-1}}", "{{if}}", "{{/if}}"] {
        #expect(throws: WorldInfoTextError.self) { try WorldInfoText.expand(text, context: &context) }
    }
    #expect(throws: WorldInfoTextError.self) {
        try WorldInfoText.expand("{{setvar::x::1}}{{unknown}}", context: &context)
    }
    #expect(context.localVariables.isEmpty)
    #expect(throws: WorldInfoTextError.self) {
        var invalid = WorldInfoTextContext(randomRolls: [1])
        _ = try WorldInfoText.expand("{{random::a::b}}", context: &invalid)
    }
    #expect(try WorldInfoText.expand("{{getvar::toString}}{{outlet::__proto__}}", context: &context) == "")
}
