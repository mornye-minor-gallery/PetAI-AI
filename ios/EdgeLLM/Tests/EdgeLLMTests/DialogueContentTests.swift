import Foundation
import Testing
@testable import EdgeLLM

@Test func dialogueContentComposesSeparateFieldsAndExamples() throws {
    let data = Data(#"{"id":"sample","name":"검사자","persona":"짧게 말한다.","situation":"입구에 있다.","knowledge":"문은 닫혀 있다.","examples":[{"user":"안녕","assistant":"반가워."}]}"#.utf8)
    let content = try DialogueContent.load(data: data)
    #expect(content.name == "검사자")
    #expect(content.promptSet.core == "## 캐릭터\n짧게 말한다.\n\n## 현재 상황\n입구에 있다.\n\n## 현재 알고 있는 정보\n문은 닫혀 있다.")
    #expect(content.exampleDialogue.contains("user: 안녕"))
    #expect(content.exampleDialogue.contains("assistant: 반가워."))
}

@Test func dialogueContentRejectsMissingIdentity() {
    #expect(throws: (any Error).self) {
        _ = try DialogueContent.load(data: Data(#"{"id":"sample","name":" ","persona":"검사"}"#.utf8))
    }
}

@Test func dialogueSelectionUsesIDIndependentlyOfDisplayName() throws {
    let content = try DialogueContent.load(data: Data(#"{"id":"test-character","name":"다른 표시 이름","persona":"검사"}"#.utf8))
    try content.validateSelection(characterID: "test-character")
    #expect(content.name == "다른 표시 이름")
    for wrongID in [nil, "", "다른 표시 이름", "other-character"] as [String?] {
        #expect(throws: DialogueContent.SelectionError.characterNotConfigured) {
            try content.validateSelection(characterID: wrongID)
        }
    }
}
