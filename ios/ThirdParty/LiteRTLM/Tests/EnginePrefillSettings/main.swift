import Foundation
import CLiteRTLM

let settings = OpaquePointer(bitPattern: 1)!
EnginePrefillSettings.apply(nil, to: settings)
precondition(test_setting_calls() == 0)
try EnginePrefillSettings.validate(128, isCPU: true)
EnginePrefillSettings.apply(128, to: settings)
precondition(test_prefill_chunk_size() == 128)
precondition(test_setting_calls() == 1)
for (size, isCPU) in [(0, true), (-1, true), (Int(Int32.max) + 1, true), (128, false)] {
    do {
        try EnginePrefillSettings.validate(size, isCPU: isCPU)
        fatalError("Invalid CPU prefill configuration was accepted")
    } catch let error as LiteRTLMError {
        precondition(error == .config(.invalidPrefillChunkSize))
    }
}
print("Engine prefill C boundary passed")
