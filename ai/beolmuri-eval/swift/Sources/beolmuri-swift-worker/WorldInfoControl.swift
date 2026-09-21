import EdgeLLM
import Foundation

/// Evaluation-only control surface. It is not linked into the shipped application.
enum WorldInfoControl {
    struct Request: Decodable {
        let id: String
        let action: String
        let name: String
        let book: String
        let entry: WorldInfoEntry?
        let entryID: String?
    }
    enum Failure: Error { case invalidAction, missingEntry }
    static func handle(_ data: Data) throws -> [String: Any] {
        let request = try JSONDecoder().decode(Request.self, from: data)
        var book = try WorldInfoImport.read(encoded: request.book, name: request.name).lorebook
        switch request.action {
        case "inspect", "export": break
        case "upsert":
            guard let entry = request.entry else { throw Failure.missingEntry }
            book = try book.upserting(entry)
        case "remove":
            guard let id = request.entryID else { throw Failure.missingEntry }
            book = try book.removing(id: id)
        default: throw Failure.invalidAction
        }
        try WorldInfoEngine.validate(.init(tokenBudget: 1, entries: book.entries))
        return ["status": "ok", "name": book.name,
            "entries": try JSONSerialization.jsonObject(with: JSONEncoder().encode(book.entries)),
            "preserved_metadata": book.preservedMetadataPaths,
            "book": String(decoding: try book.exportData(), as: UTF8.self)]
    }
}
