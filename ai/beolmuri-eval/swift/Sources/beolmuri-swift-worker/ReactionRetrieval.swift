import EdgeLLM
import Foundation

actor ReactionRetrieval {
    static let shared = ReactionRetrieval()
    private var cached: [String: DialogueRetrievalResources] = [:]

    func prepare(directory: String, content: DialogueContent, requestID: String,
                 history: [String], message: String, base: WorldInfoSettings?) throws -> (WorldInfoSettings?, Data) {
        guard let options = content.retrieval else { return (base, Data("{}".utf8)) }
        let key = directory + ":\(content.id):\(options.reactions):\(options.worldLore)"
        let resources: DialogueRetrievalResources
        if let existing = cached[key] { resources = existing }
        else {
            resources = try .init(directory: URL(fileURLWithPath: directory), characterID: content.id,
                                  reactions: options.reactions, worldLore: options.worldLore)
            cached[key] = resources
        }
        var trace: [String: Any] = ["reactions": options.reactions, "world_lore": options.worldLore]
        var match: ReactionFrameIndex.Match?
        if let index = resources.index {
            let query = ReactionFrameIndex.query(history: history, current: message)
            let started = ProcessInfo.processInfo.systemUptime
            try Worker.emit(["id": requestID, "protocol_version": 1, "status": "embedding_required", "text": query])
            guard let line = readLine() else { throw RetrievalError.disconnected }
            let response = try JSONDecoder().decode(Response.self, from: Data(line.utf8))
            guard response.id == requestID, response.protocol_version == 1, response.status == "embedding_result" else { throw RetrievalError.protocolMismatch }
            if let error = response.error { throw RetrievalError.native(error) }
            guard let vector = response.vector, let identity = response.identity else { throw RetrievalError.protocolMismatch }
            trace["embedding_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            let found = try index.search(query: vector, embeddingIdentity: identity)
            match = found
            trace["selected_id"] = found.frame.id; trace["score"] = found.score
            trace["example_row"] = found.exampleRow; trace["search_ms"] = found.searchMilliseconds
            trace["query"] = query; trace["query_messages"] = min(3, history.count + 1)
            trace["embedding_identity"] = identity
        }
        return (resources.worldInfo(base: base, match: match), try JSONSerialization.data(withJSONObject: trace))
    }
    private struct Response: Decodable {
        let id: String; let protocol_version: Int; let status: String
        let vector: [Float]?; let identity: String?; let error: String?
    }
    enum RetrievalError: Error { case disconnected, protocolMismatch, native(String) }
}
