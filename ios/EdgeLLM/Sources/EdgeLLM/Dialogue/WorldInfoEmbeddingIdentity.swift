import Foundation
#if os(Android)
import Crypto
#else
import CryptoKit
#endif

public enum WorldInfoEmbeddingIdentity {
    /// Content identity includes the tokenizer and preprocessing contract, not a filename or model label.
    public static func make(modelURL: URL, tokenizerURL: URL, preprocessing: String) throws -> String {
        var digest = SHA256()
        for value in [preprocessing, try hashFile(modelURL), try hashFile(tokenizerURL)] {
            digest.update(data:Data(value.utf8)); digest.update(data:Data([0]))
        }
        return digest.finalize().map { String(format:"%02x",$0) }.joined()
    }
    private static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom:url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount:1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data:chunk)
        }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
