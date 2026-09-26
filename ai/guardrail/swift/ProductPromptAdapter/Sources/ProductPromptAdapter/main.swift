import Foundation
import ProductAdapterCore

enum AdapterError: Error, CustomStringConvertible {
    case usage
    case invalidUTF8

    var description: String {
        switch self {
        case .usage:
            return "usage: product-prompt-adapter prompt|normalize"
        case .invalidUTF8:
            return "stdin contains invalid UTF-8"
        }
    }
}

private let encoder: JSONEncoder = {
    let value = JSONEncoder()
    value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return value
}()

private func printJSON<T: Encodable>(_ value: T) throws {
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func runNormalize() throws {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: input, encoding: .utf8) else {
        throw AdapterError.invalidUTF8
    }
    let decoder = JSONDecoder()
    for line in text.split(whereSeparator: \.isNewline) {
        let record = try decoder.decode(RawResponseRecord.self, from: Data(line.utf8))
        try printJSON(ProductResponseNormalizer.normalize(record))
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw AdapterError.usage
    }
    switch CommandLine.arguments[1] {
    case "prompt":
        try printJSON(ProductPromptSnapshot())
    case "normalize":
        try runNormalize()
    default:
        throw AdapterError.usage
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}
