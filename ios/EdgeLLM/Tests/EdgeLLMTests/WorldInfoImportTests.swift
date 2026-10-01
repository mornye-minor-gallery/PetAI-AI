import Foundation
import Testing
@testable import EdgeLLM

@Test func characterBookImportPreservesAnchorsAndMetadata() throws {
    let data = Data(#"{"spec":"chara_card_v2","data":{"name":"Elena","description":"kind","character_book":{"name":"forest","entries":[{"keys":["tree"],"content":"old oak","enabled":true,"extensions":{"sticky":3}}]}}}"#.utf8)
    let imported = try WorldInfoImport.read(data: data, name: "forest")
    #expect(imported.lorebook.entries[0].position == .afterCharacter)
    #expect(imported.lorebook.entries[0].rules.sticky == 3)
    #expect(imported.character?["name"] == .string("Elena"))
    #expect(imported.lorebook.preservedMetadataPaths.contains("originalData"))
}

@Test func risuZeroProbabilityPreservesUpstreamTruthiness() throws {
    let data = Data(#"{"type":"risu","data":[{"key":"a,b","secondkey":"c","content":"text","activationPercent":0}]}"#.utf8)
    let imported = try WorldInfoImport.read(data: data, name: "risu")
    #expect(imported.lorebook.entries[0].keys == ["a", "b"])
    #expect(imported.lorebook.entries[0].rules.probability == nil)
}

@Test func nativeImportsMatchUpstreamEntryProjections() throws {
    let url = try #require(Bundle.module.url(forResource:"native-import-upstream",withExtension:"json"))
    let root = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
    for record in try #require(root["cases"] as? [[String:Any]]) {
        let name = try #require(record["id"] as? String)
        let expected = try WorldInfoLorebook(data:JSONSerialization.data(withJSONObject:record["expected"]!),name:name)
        let actual = try WorldInfoImport.read(data:JSONSerialization.data(withJSONObject:record["input"]!),name:name)
        #expect(actual.lorebook.entries == expected.entries, "\(name)")
    }
}
@Test func pngCardMetadataPrefersV3AndRejectsTruncation() throws {
    func chunk(_ type: String, _ payload: Data) -> Data {
        var size = UInt32(payload.count).bigEndian
        var result = withUnsafeBytes(of:&size) { Data($0) }
        result.append(Data(type.utf8)); result.append(payload); result.append(Data(repeating:0,count:4))
        return result
    }
    let card = Data(#"{"data":{"character_book":{"entries":[{"keys":["a"],"content":"v3","enabled":true}]}}}"#.utf8)
    var png = Data(PNGTextMetadata.signature)
    png.append(chunk("tEXt",Data("chara\0e30=".utf8)))
    png.append(chunk("tEXt",Data("ccv3\0".utf8)+card.base64EncodedData()))
    png.append(chunk("IEND",Data()))
    #expect(try WorldInfoImport.read(data:png,name:"test").lorebook.entries.first?.content == "v3")
    #expect(throws:WorldInfoImportError.self) { try WorldInfoImport.read(data:png.dropLast(),name:"test") }
}

@Test func characterWithoutLorebookStillImportsItsFields() throws {
    let card = try DialogueCharacterCard(data:Data(#"{"spec":"chara_card_v3","data":{"name":"Elena","description":"kind"}}"#.utf8),lorebookName:"unused")
    #expect(card.fields["description"] == .string("kind"))
    #expect(card.lorebook == nil)
}
