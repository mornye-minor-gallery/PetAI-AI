import Foundation

/// Reads metadata only; no image decoder, executable content or external asset loading.
enum PNGTextMetadata {
    static let signature: [UInt8] = [137,80,78,71,13,10,26,10]
    static func json(_ data: Data) throws -> Data {
        let bytes = Array(data)
        guard bytes.starts(with:signature) else { throw WorldInfoImportError.invalidPNG }
        var index = 8, records: [String:Data] = [:], ended = false
        while index < bytes.count {
            guard bytes.count-index >= 12 else { throw WorldInfoImportError.invalidPNG }
            let count = bytes[index..<(index+4)].reduce(0) { ($0 << 8) | Int($1) }
            guard count <= bytes.count-index-12 else { throw WorldInfoImportError.invalidPNG }
            let type = String(decoding:bytes[(index+4)..<(index+8)],as:UTF8.self)
            if type == "tEXt" {
                let payload = bytes[(index+8)..<(index+8+count)]
                guard let zero = payload.firstIndex(of:0) else { throw WorldInfoImportError.invalidPNG }
                let name = String(decoding:bytes[(index+8)..<zero],as:UTF8.self).lowercased()
                if records[name] == nil { records[name] = Data(bytes[(zero+1)..<(index+8+count)]) }
            }
            index += count+12
            if type == "IEND" { ended = true; break }
        }
        guard ended else { throw WorldInfoImportError.invalidPNG }
        // Character-card v3 takes precedence regardless of chunk order, as upstream does.
        guard let encoded = records["ccv3"] ?? records["chara"] ?? records["naidata"],
              let decoded = Data(base64Encoded:encoded) else { throw WorldInfoImportError.missingMetadata }
        return decoded
    }
}
