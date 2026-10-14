import Foundation

public enum DialogueCharacterIDError: Error { case invalidID }

/// An authored ID is also a directory component in the device-local chat store.
public struct DialogueCharacterID: Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 64,
              bytes[0] >= 97, bytes[0] <= 122,
              bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
        else { throw DialogueCharacterIDError.invalidID }
        self.value = value
    }
}
