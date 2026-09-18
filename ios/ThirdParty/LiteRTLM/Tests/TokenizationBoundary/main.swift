import Foundation
import CLiteRTLM

func expectError(_ expected: LiteRTLMError, _ operation: () throws -> Int) {
    do {
        _ = try operation()
        fatalError("Expected \(expected)")
    } catch {
        precondition(error as? LiteRTLMError == expected, "Unexpected error: \(error)")
    }
}

let engine = OpaquePointer(bitPattern: 1)!
expectError(.engine(.notInitialized)) { try NativeTokenization.count("한글🌟", engine: nil) }
expectError(.engine(.invalidTokenizationInput)) { try NativeTokenization.count("앞\0뒤", engine: engine) }
precondition(test_tokenization_calls() == 0, "Invalid inputs reached native code")
for _ in 0..<100 {
    let count = try NativeTokenization.count("한글🌟", engine: engine)
    precondition(count == 7, "UTF-8 text or native count was not preserved")
    precondition(test_live_results() == 0, "Native result leaked")
}
let empty = try NativeTokenization.count("", engine: engine)
precondition(empty == 0)
expectError(.engine(.tokenizationFailed)) { try NativeTokenization.count("native failure", engine: engine) }
expectError(.engine(.invalidTokenCount)) { try NativeTokenization.count("overflow", engine: engine) }
precondition(test_live_results() == 0, "Native result leaked on error")
print("Tokenization C boundary passed (stub ABI; no model inference)")
