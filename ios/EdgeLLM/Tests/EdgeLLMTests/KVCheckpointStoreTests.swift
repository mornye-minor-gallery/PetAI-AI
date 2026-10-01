import Foundation
import Testing
@testable import EdgeLLM

struct KVCheckpointStoreTests {
    @Test func identityBindsOnlyFormatModelAndContextCapacity() {
        let a = KVCheckpointStore.identity(modelIdentity: "a", contextTokens: 4096)
        #expect(a == "app-kv-v3:a:4096")
        #expect(a != KVCheckpointStore.identity(modelIdentity: "b", contextTokens: 4096))
        #expect(a != KVCheckpointStore.identity(modelIdentity: "a", contextTokens: 8192))
    }
    @Test func existenceAndIdempotentRemovalIncludeTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KVCheckpointStore(directory: root)
        #expect(!store.exists)
        try Data("previous".utf8).write(to: store.fileURL)
        try Data("interrupted write".utf8).write(to: store.temporaryURL)
        #expect(store.exists)
        try store.remove()
        #expect(!store.exists)
        #expect(!FileManager.default.fileExists(atPath: store.temporaryURL.path))
        try store.remove() // Idempotent deletion.
    }
    @Test func modelIdentitySurvivesFileRecreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model")
        try Data("abc".utf8).write(to: model)
        let first = KVCheckpointStore.modelIdentity(at: model)
        #expect(first == "model")
        #expect(first == KVCheckpointStore.modelIdentity(at: model))
        let store = try KVCheckpointStore(directory: root.appendingPathComponent("cache"))
        var bytes = [UInt8](repeating: 7, count: 64)
        try store.save(identity: first) { io in
            try bytes.withUnsafeMutableBytes { try io($0.baseAddress, $0.count) }
            try io(nil, 0)
        }
        try Data("abc".utf8).write(to: model, options: .atomic)
        #expect(first == KVCheckpointStore.modelIdentity(at: model))
        let reopened = try KVCheckpointStore(directory: root.appendingPathComponent("cache"))
        bytes = [UInt8](repeating: 0, count: 64)
        try reopened.restore(identity: KVCheckpointStore.modelIdentity(at: model)) { io in
            try bytes.withUnsafeMutableBytes { try io($0.baseAddress, $0.count) }
            try io(nil, 0)
        }
        #expect(bytes.allSatisfy { $0 == 7 })
    }

    @Test func streamedRoundTripAndFailedWritePreservesPreviousFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KVCheckpointStore(directory: root)
        var bytes = [UInt8](repeating: 7, count: 65536)
        try store.save(identity: "model") { io in
            try bytes.withUnsafeMutableBytes { try io($0.baseAddress, $0.count) }
            try io(nil, 0)
        }
        let saved = try Data(contentsOf: store.fileURL)
        #expect(throws: KVCheckpointError.self) {
            try store.save(identity: "model") { io in
                try bytes.withUnsafeMutableBytes { try io($0.baseAddress, $0.count) }
                throw KVCheckpointError.invalidData
            }
        }
        #expect(try Data(contentsOf: store.fileURL) == saved)
        #expect(!FileManager.default.fileExists(atPath: store.temporaryURL.path))
        bytes = [UInt8](repeating: 0, count: bytes.count)
        try store.restore(identity: "model") { io in
            try bytes.withUnsafeMutableBytes { try io($0.baseAddress, $0.count) }
            try io(nil, 0)
        }
        #expect(bytes.allSatisfy { $0 == 7 })
    }

    @Test func rejectsWrongIdentityTruncationCorruptionAndTrailingBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KVCheckpointStore(directory: root)
        var bytes = [UInt8](repeating: 7, count: 64)
        try store.save(identity: "model") { io in
            try bytes.withUnsafeMutableBytes { try io($0.baseAddress, $0.count) }
            try io(nil, 0)
        }
        #expect(throws: KVCheckpointError.self) {
            try store.restore(identity: "other") { _ in Issue.record("identity must be checked before native restore") }
        }
        let valid = try Data(contentsOf: store.fileURL)
        var corrupt = valid
        corrupt[corrupt.count - 33] ^= 1
        for invalid in [Data(valid.dropLast()), corrupt, valid + Data([0])] {
            try invalid.write(to: store.fileURL)
            #expect(throws: KVCheckpointError.self) {
                try store.restore(identity: "model") { io in
                    try bytes.withUnsafeMutableBytes { try io($0.baseAddress, $0.count) }
                    try io(nil, 0)
                }
            }
        }
    }

    @Test func requiresFinalizationBeforePublishing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try KVCheckpointStore(directory: root)
        #expect(throws: KVCheckpointError.self) { try store.save(identity: "model") { _ in } }
        #expect(!store.exists)
    }
}
