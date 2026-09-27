import Foundation

/// Arrays keep this request directly serializable with Unity JsonUtility.
/// Game state is selected by the host. These values cannot invoke tools or alter saves.
struct NativeWorldInfoInput: Decodable, Sendable {
    struct Field: Decodable, Sendable { let key: String; let value: String }
    let characterTags: [String]?
    let trigger: String?
    let scanFields: [Field]?
    let externallyActivated: [String]?
    let randomSeed: UInt64?

    func context() throws -> WorldInfoContext {
        var result = WorldInfoContext()
        result.characterTags = characterTags ?? []
        result.trigger = trigger ?? "normal"
        result.externallyActivated = externallyActivated ?? []
        result.randomSeed = randomSeed ?? 1
        for field in scanFields ?? [] {
            guard result.scanFields[field.key] == nil else { throw WorldInfoError.invalidRule("duplicate scan field") }
            result.scanFields[field.key] = field.value
        }
        return result
    }
}
