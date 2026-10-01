#if os(Android)
import Foundation
import CEmbeddingGemma

final class PETEmbeddingGemmaRunner {
    private let core: OpaquePointer
    let dimension: Int

    init(modelPath: String, tokenizerPath: String, sequenceLength: Int) throws {
        var code: Int32 = 0
        var message = [CChar](repeating: 0, count: 1024)
        guard let core = pet_embedding_create(modelPath, tokenizerPath, Int32(sequenceLength),
                                              &code, &message, message.count) else {
            throw NSError(domain: "EmbeddingGemma", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: message)])
        }
        self.core = core
        dimension = Int(pet_embedding_dimension(core))
    }

    deinit { pet_embedding_delete(core) }

    func embedding(forText text: String) throws -> Data {
        var output = [Float](repeating: 0, count: dimension)
        var message = [CChar](repeating: 0, count: 1024)
        let code = pet_embedding_compute(core, text, &output, output.count, &message, message.count)
        guard code == 0 else {
            throw NSError(domain: "EmbeddingGemma", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: message)])
        }
        return output.withUnsafeBytes { Data($0) }
    }
}
#endif
