import Foundation

/// Original JSON books and explicit host bindings. Entries in `settings.entries`
/// form an additional global book; chat/persona bindings retain source priority.
public struct WorldInfoLibraryConfiguration: Codable, Equatable, Sendable {
    public var books: [String: String]
    public var global: [String]
    public var characters: [String: [String]]
    public var chat: String?
    public var persona: String?
    public var strategy: WorldInfoLibrary.Strategy
    public init(books: [String: String], global: [String] = [], characters: [String: [String]] = [:],
                chat: String? = nil, persona: String? = nil, strategy: WorldInfoLibrary.Strategy = .even) {
        self.books = books; self.global = global; self.characters = characters
        self.chat = chat; self.persona = persona; self.strategy = strategy
    }
    public func entries(character: String) throws -> [WorldInfoEntry] {
        let library = try WorldInfoLibrary(lorebooks: books.keys.sorted().map {
            try WorldInfoLorebook(data: Data(books[$0]!.utf8), name: $0)
        })
        return try library.select(global: global, character: characters[character] ?? [], chat: chat, persona: persona, strategy: strategy)
    }
}
