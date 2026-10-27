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
        if let index = resources.index, let gate = resources.queryGate {
            let started = ProcessInfo.processInfo.systemUptime
            let current = try embedding(message, requestID: requestID)
            let messageCount = try gate.select(current: message, embedding: current.vector,
                                               embeddingIdentity: current.identity)
            let query = ReactionFrameIndex.query(history: history, current: message, messageCount: messageCount)
            let result = query == message ? current : try embedding(query, requestID: requestID)
            trace["embedding_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            let found = try index.search(query: result.vector, embeddingIdentity: result.identity)
            match = found
            trace["selected_id"] = found.frame.id; trace["score"] = found.score
            trace["example_row"] = found.exampleRow; trace["search_ms"] = found.searchMilliseconds
            trace["query"] = query; trace["query_messages"] = min(messageCount.rawValue, history.count + 1)
            trace["embedding_identity"] = result.identity
        }
        return (resources.worldInfo(base: base, match: match), try JSONSerialization.data(withJSONObject: trace))
    }
    private func embedding(_ text: String, requestID: String) throws -> (vector: [Float], identity: String) {
        try Worker.emit(["id": requestID, "protocol_version": 1, "status": "embedding_required", "text": text])
        guard let line = readLine() else { throw RetrievalError.disconnected }
        let response = try JSONDecoder().decode(Response.self, from: Data(line.utf8))
        guard response.id == requestID, response.protocol_version == 1, response.status == "embedding_result" else {
            throw RetrievalError.protocolMismatch
        }
        if let error = response.error { throw RetrievalError.native(error) }
        guard let vector = response.vector, let identity = response.identity else { throw RetrievalError.protocolMismatch }
        return (vector, identity)
    }
    private struct Response: Decodable {
        let id: String; let protocol_version: Int; let status: String
        let vector: [Float]?; let identity: String?; let error: String?
    }
    enum RetrievalError: Error { case disconnected, protocolMismatch, native(String) }
}
