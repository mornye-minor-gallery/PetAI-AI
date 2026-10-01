import Foundation

/// File import only. Binding these fields to a game's character identity is the host's decision.
public struct DialogueCharacterCard: Sendable {
    public let fields: [String:JSONValue]
    public let lorebook: WorldInfoLorebook?
    public init(data: Data, lorebookName: String) throws {
        let bytes = data.starts(with:PNGTextMetadata.signature) ? try PNGTextMetadata.json(data) : data
        let root = try JSONDecoder().decode([String:JSONValue].self,from:bytes)
        if case .object(let nested) = root["data"] { fields = nested } else { fields = root }
        guard case .string = fields["name"] else { throw WorldInfoImportError.invalidFormat }
        if fields["character_book"] != nil {
            lorebook = try WorldInfoImport.read(data:bytes,name:lorebookName).lorebook
        } else { lorebook = nil }
    }
}
