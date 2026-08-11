import Foundation

enum Float32ArtifactDecoder {
    static func decodeLittleEndian(
        _ data: Data,
        expectedCount: Int
    ) -> [Float]? {
        guard expectedCount >= 0,
              data.count == expectedCount * MemoryLayout<UInt32>.size
        else {
            return nil
        }

        var values = [Float]()
        values.reserveCapacity(expectedCount)
        var byteIndex = data.startIndex
        for _ in 0..<expectedCount {
            let nextIndex = data.index(byteIndex, offsetBy: 4)
            let bits = data[byteIndex..<nextIndex]
                .enumerated()
                .reduce(UInt32(0)) { partial, pair in
                    partial | (UInt32(pair.element) << UInt32(pair.offset * 8))
                }
            let value = Float(bitPattern: bits)
            guard value.isFinite else { return nil }
            values.append(value)
            byteIndex = nextIndex
        }
        return values
    }
}
