#if RESOURCE_BENCH
import Foundation
import CryptoKit
import Darwin

nonisolated public enum BenchIO {
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func digestFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        // FileHandle's NSData buffers can otherwise survive until the worker's
        // outer autorelease pool drains, contaminating model-before RAM by file size.
        while try autoreleasepool(invoking: {
            guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { return false }
            hash.update(data: chunk)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func atomic<T: Encodable>(_ value: T, to url: URL) throws {
        try atomicData(BenchJSON.encoder.encode(value), to: url)
    }
    public static func atomicData(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw BenchFailure.invalid("create_checkpoint_failed")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        } catch {
            try? handle.close() // Preserve the original write error and partial checkpoint.
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    public static func safeURL(_ relative: String, under root: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw BenchFailure.invalid("unsafe_relative_path")
        }
        var result = root
        for part in parts {
            result.appendPathComponent(String(part))
            if FileManager.default.fileExists(atPath: result.path),
               try result.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw BenchFailure.invalid("symbolic_link_not_allowed")
            }
        }
        return result
    }
    public static func nanoseconds() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        // Quotient/remainder avoids overflowing ticks * numer on long uptimes.
        return (ticks / UInt64(info.denom)) * UInt64(info.numer)
             + (ticks % UInt64(info.denom)) * UInt64(info.numer) / UInt64(info.denom)
    }
}
#endif
