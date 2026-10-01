import Foundation
import Testing
@testable import EdgeLLM

@Test func vectorIndexReusesPersistsUpdatesAndDeletesDocuments() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("index.json")
    let index = try WorldInfoVectorIndex(url: url, embeddingIdentity: "test-v1")
    let entries = [WorldInfoEntry(id: "book.1", keys: [], content: "forest")]
    let settings = WorldInfoVectorSettings(enabledForAll: true)
    let first = try await index.search(entries: entries, newestMessages: ["forest"], settings: settings,
        embedQuery: { _ in [1, 0] }, embedDocument: { _ in [1, 0] })
    #expect(first.map(\.id) == ["book.1"])
    let restored = try WorldInfoVectorIndex(url: url, embeddingIdentity: "test-v1")
    let reused = try await restored.search(entries: entries, newestMessages: ["forest"], settings: settings,
        embedQuery: { _ in [1, 0] }, embedDocument: { _ in throw TestIndexError.unexpectedEmbedding })
    #expect(reused == first)
    _ = try await restored.search(entries: [], newestMessages: ["forest"], settings: settings,
        embedQuery: { _ in [1, 0] }, embedDocument: { _ in [1, 0] })
    #expect(await restored.documentCount == 0)
    #expect(throws: WorldInfoVectorIndexError.self) { try WorldInfoVectorIndex(url: url, embeddingIdentity: "changed") }
}
private enum TestIndexError: Error { case unexpectedEmbedding }

@Test func vectorIndexChangedContentAndFailedRefreshAreAtomic() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let url = directory.appendingPathComponent("index.json")
    let index = try WorldInfoVectorIndex(url:url,embeddingIdentity:"v1")
    let settings = WorldInfoVectorSettings(enabledForAll:true)
    let original = [WorldInfoEntry(id:"b.0",content:"old")]
    _ = try await index.search(entries:original,newestMessages:["q"],settings:settings,embedQuery:{ _ in [1,0] },embedDocument:{ _ in [1,0] })
    let before = try Data(contentsOf:url)
    await #expect(throws:TestIndexError.self) {
        try await index.search(entries:[.init(id:"b.0",content:"new")],newestMessages:["q"],settings:settings,
            embedQuery:{ _ in [1,0] },embedDocument:{ _ in throw TestIndexError.unexpectedEmbedding })
    }
    #expect(try Data(contentsOf:url) == before)
    let unchanged = try await index.search(entries:original,newestMessages:["q"],settings:settings,
        embedQuery:{ _ in [1,0] },embedDocument:{ _ in throw TestIndexError.unexpectedEmbedding })
    #expect(unchanged.first?.score == 1)
    let changed = try await index.search(entries:[.init(id:"b.0",content:"new")],newestMessages:["q"],settings:settings,
        embedQuery:{ _ in [1,0] },embedDocument:{ _ in [0,1] })
    #expect(changed.isEmpty)
}
