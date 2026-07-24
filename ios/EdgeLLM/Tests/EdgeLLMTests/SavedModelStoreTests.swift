import Foundation
import Testing
@testable import EdgeLLM

@Test func savedModelStoreImportsModelIntoManagedDirectory() throws {
    let fixture = try SavedModelStoreFixture()
    defer { fixture.remove() }
    let source = try fixture.writeSource(
        named: "gemma.litertlm",
        contents: "model-v1"
    )

    let destination = try fixture.store.importModel(from: source)

    #expect(try fixture.store.hasSavedModel())
    #expect(destination.lastPathComponent == "selected-model.litertlm")
    #expect(try String(contentsOf: destination) == "model-v1")
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func savedModelStoreReplacesExistingModel() throws {
    let fixture = try SavedModelStoreFixture()
    defer { fixture.remove() }
    let first = try fixture.writeSource(
        named: "first.litertlm",
        contents: "model-v1"
    )
    let second = try fixture.writeSource(
        named: "second.litertlm",
        contents: "model-v2"
    )
    _ = try fixture.store.importModel(from: first)

    let destination = try fixture.store.importModel(from: second)

    #expect(try String(contentsOf: destination) == "model-v2")
}

@Test func savedModelStoreRejectsWrongExtension() throws {
    let fixture = try SavedModelStoreFixture()
    defer { fixture.remove() }
    let source = try fixture.writeSource(
        named: "model.bin",
        contents: "model"
    )

    #expect(throws: SavedModelStoreError.invalidModelFileExtension) {
        try fixture.store.importModel(from: source)
    }
}

@Test func savedModelStoreRejectsEmptyModel() throws {
    let fixture = try SavedModelStoreFixture()
    defer { fixture.remove() }
    let source = try fixture.writeSource(
        named: "empty.litertlm",
        contents: ""
    )

    #expect(throws: SavedModelStoreError.emptyModelFile) {
        try fixture.store.importModel(from: source)
    }
}

@Test func savedModelStoreDeletesManagedModel() throws {
    let fixture = try SavedModelStoreFixture()
    defer { fixture.remove() }
    let source = try fixture.writeSource(
        named: "gemma.litertlm",
        contents: "model"
    )
    _ = try fixture.store.importModel(from: source)

    try fixture.store.deleteSavedModel()

    #expect(try !fixture.store.hasSavedModel())
}

private struct SavedModelStoreFixture {
    let root: URL
    let sources: URL
    let store: SavedModelStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SavedModelStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        sources = root.appendingPathComponent(
            "Sources",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )
        store = SavedModelStore(
            modelDirectory: root.appendingPathComponent(
                "Models",
                isDirectory: true
            )
        )
    }

    func writeSource(
        named name: String,
        contents: String
    ) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
