import Foundation
#if os(Android)
import Crypto
#else
import CryptoKit
#endif
#if os(Android)
import Android
#else
import Darwin
#endif

/// One latest native text-session cache per device, not another dialogue archive.
/// The authoritative recent turns remain in DialogueSessionFileStore. All input
/// is resubmitted after restore and native token-prefix matching governs reuse.
public struct KVCheckpointStore: Sendable {
    public let fileURL: URL
    public var temporaryURL: URL { URL(fileURLWithPath: fileURL.path + ".tmp") }
    public var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    public init(directory: URL) throws {
        // Android callers supply an app-private cache/no-backup directory;
        // Apple's resource attribute does not configure Android backup rules.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if !os(Android)
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
#endif
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: directory.path)
#endif
        fileURL = directory.appendingPathComponent("latest.kv")
        // Atomic rename keeps the last completed file authoritative after a kill.
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        }
    }

    public static func deviceLocal() throws -> Self {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        return try Self(directory: caches.appendingPathComponent("LiteRTLM/Session", isDirectory: true))
    }

    public func remove() throws {
        for url in [fileURL, temporaryURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func modelIdentity(at url: URL) -> String {
        url.lastPathComponent
    }

    public static func identity(modelIdentity: String, contextTokens: Int) -> String {
        ["app-kv-v3", modelIdentity, String(contextTokens)].joined(separator: ":")
    }

    public typealias Transfer = (UnsafeMutableRawPointer?, Int) throws -> Void

    public func save(identity: String, transfer: (Transfer) throws -> Void) throws {
        let file = try KVCheckpointFile(url: temporaryURL, reading: false)
        defer {
            file.close()
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        try file.header(identity)
        try transfer(file.transfer)
        guard file.finished else { throw KVCheckpointError.invalidData }
        try file.synchronizeAndClose()
        guard rename(temporaryURL.path, fileURL.path) == 0 else { throw KVCheckpointError.io(errno) }
    }

    public func restore(identity: String, transfer: (Transfer) throws -> Void) throws {
        let file = try KVCheckpointFile(url: fileURL, reading: true)
        defer { file.close() }
        try file.header(identity)
        try transfer(file.transfer)
        guard file.finished else { throw KVCheckpointError.invalidData }
    }
}

public enum KVCheckpointError: Error {
    case invalidData, io(Int32)
}

private final class KVCheckpointFile {
    private var descriptor: Int32
    private let reading: Bool
    private var digest = SHA256()
    private(set) var finished = false

    init(url: URL, reading: Bool) throws {
        self.reading = reading
        descriptor = KVFileSystem.open(url.path, reading ? O_RDONLY | O_NOFOLLOW : O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw KVCheckpointError.io(errno) }
    }

    func close() {
        if descriptor >= 0 { _ = KVFileSystem.close(descriptor); descriptor = -1 }
    }

    func synchronizeAndClose() throws {
        guard fsync(descriptor) == 0 else { throw KVCheckpointError.io(errno) }
        let result = KVFileSystem.close(descriptor)
        descriptor = -1
        guard result == 0 else { throw KVCheckpointError.io(errno) }
    }

    func header(_ identity: String) throws {
        let expected = Array(("PetAI-KV-v2\n" + identity + "\n").utf8)
        var bytes = expected
        try bytes.withUnsafeMutableBytes { try bytesIO($0.baseAddress!, $0.count) }
        guard bytes == expected else { throw KVCheckpointError.invalidData }
    }

    func transfer(_ pointer: UnsafeMutableRawPointer?, _ size: Int) throws {
        guard descriptor >= 0, !finished, size >= 0 else { throw KVCheckpointError.invalidData }
        if let pointer, size > 0 {
            try bytesIO(pointer, size)
            digest.update(bufferPointer: UnsafeRawBufferPointer(start: pointer, count: size))
        } else if pointer == nil, size == 0 {
            let expected = Array(digest.finalize())
            var bytes = expected
            try bytes.withUnsafeMutableBytes { try bytesIO($0.baseAddress!, $0.count) }
            guard bytes == expected else { throw KVCheckpointError.invalidData }
            if reading {
                var extra: UInt8 = 0
                var count: Int
                repeat { count = KVFileSystem.read(descriptor, &extra, 1) } while count < 0 && errno == EINTR
                guard count == 0 else { throw KVCheckpointError.invalidData }
            }
            finished = true
        } else {
            throw KVCheckpointError.invalidData
        }
    }

    private func bytesIO(_ pointer: UnsafeMutableRawPointer, _ size: Int) throws {
        var offset = 0
        while offset < size {
            let count = reading ? KVFileSystem.read(descriptor, pointer + offset, size - offset)
                                : KVFileSystem.write(descriptor, pointer + offset, size - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                if count == 0 { throw KVCheckpointError.invalidData }
                throw KVCheckpointError.io(errno)
            }
            offset += count
        }
    }
}
