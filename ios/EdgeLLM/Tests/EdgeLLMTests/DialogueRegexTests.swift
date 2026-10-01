import Foundation
import Testing
@testable import EdgeLLM

@Test func regexRegistryFiltersOrdersAndTrimsCaptures() throws {
    let settings = try JSONDecoder().decode(DialogueRegexSettings.self, from:Data(#"{"global":[{"findRegex":"/(cat)/g","replaceString":"[$1]","trimStrings":["a"],"placement":[5],"minDepth":1}],"preset":[{"findRegex":"/ct/g","replaceString":"dog","placement":[5]}],"presetAllowed":true}"#.utf8))
    var context = WorldInfoTextContext(); context.regex = settings
    var request = DialogueRegexRequest(placement:5); request.depth = 0
    #expect(try DialogueRegex.apply("cat cat",request:request,context:&context) == "cat cat")
    request.depth = 1
    #expect(try DialogueRegex.apply("cat cat",request:request,context:&context) == "[dog] [dog]")
    request.isPrompt = true
    #expect(try DialogueRegex.apply("cat",request:request,context:&context) == "cat")
}
@Test func regexEscapesOnlyMacroResultsInFindPattern() throws {
    var script = DialogueRegexScript(findRegex:"/^{{char}}$/",replaceString:"yes")
    script.substituteRegex = 2
    var settings = DialogueRegexSettings(); settings.global = [script]
    var context = WorldInfoTextContext(char:"a.b"); context.regex = settings
    #expect(try DialogueRegex.apply("a.b",request:.init(placement:5),context:&context) == "yes")
    #expect(try DialogueRegex.apply("axb",request:.init(placement:5),context:&context) == "axb")
}
@Test func regexUsesExplicitASCIIClassesAndEndAnchor() throws {
    #expect(try WorldInfoText.matchesRegex(#"/\d/"#,text:"١") == false)
    #expect(try WorldInfoText.matchesRegex(#"/\w/"#,text:"한") == false)
    #expect(try WorldInfoText.matchesRegex("/a$/",text:"a\n") == false)
    #expect(try WorldInfoText.matchesRegex(#"/\s/"#,text:"\u{FEFF}") == true)
    #expect(throws:WorldInfoTextError.self) { try WorldInfoText.matchesRegex("/ss/i",text:"ß") }
}

@Test func trimMacrosRunOnlyForReferencedCapturesOfActualMatches() throws {
    var script = DialogueRegexScript(findRegex:"/a/g",replaceString:"$0")
    script.trimStrings = ["{{incvar::n}}"]
    var settings = DialogueRegexSettings(); settings.global = [script]
    var context = WorldInfoTextContext(); context.regex = settings
    #expect(try DialogueRegex.apply("z",request:.init(placement:5),context:&context) == "z")
    #expect(context.localVariables["n"] == nil)
    #expect(try DialogueRegex.apply("a a",request:.init(placement:5),context:&context) == "a a")
    #expect(context.localVariables["n"] == "2")
}
