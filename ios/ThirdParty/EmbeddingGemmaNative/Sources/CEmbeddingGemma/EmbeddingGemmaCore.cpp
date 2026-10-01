#include "EmbeddingGemmaCore.h"
#if defined(__APPLE__)
#include <CLiteRT/CLiteRT.h>
#include <CSentencePiece.h>
#else
#include "litert/c/litert_environment.h"
#include "litert/c/litert_model.h"
#include "litert/c/litert_options.h"
#include "litert/c/litert_compiled_model.h"
#include "litert/c/litert_tensor_buffer.h"
#include "litert/c/litert_tensor_buffer_requirements.h"
#include "sentencepiece_processor.h"
#endif
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

namespace {
struct Failure : std::runtime_error {
    int code;
    Failure(int code, const std::string& text) : std::runtime_error(text), code(code) {}
};
void check(LiteRtStatus status, int code, const char* operation) {
    if (status != kLiteRtStatusOk) throw Failure(code, std::string(operation) + ": " + std::to_string(status));
}
void message(const char* text, char* output, size_t capacity) {
    if (!output || !capacity) return;
    const auto count = std::min(std::strlen(text), capacity - 1);
    std::memcpy(output, text, count);
    output[count] = 0;
}
}

// The tensor contract and token construction follow Google's Apache-2.0
// LiteRT semantic-similarity sample:
// google-ai-edge/litert-samples/compiled_model_api/semantic_similarity.
// The same CPU tensor and BOS/content/EOS/PAD contract serves both platform adapters.
struct PETEmbeddingCore {
    sentencepiece::SentencePieceProcessor tokenizer;
    LiteRtEnvironment environment = nullptr;
    LiteRtModel model = nullptr;
    LiteRtCompiledModel compiled = nullptr;
    LiteRtTensorBuffer input = nullptr, output = nullptr;
    int sequence = 0, dimension = 0;
    ~PETEmbeddingCore() {
        if (input) LiteRtDestroyTensorBuffer(input);
        if (output) LiteRtDestroyTensorBuffer(output);
        if (compiled) LiteRtDestroyCompiledModel(compiled);
        if (model) LiteRtDestroyModel(model);
        if (environment) LiteRtDestroyEnvironment(environment);
    }
    void prepare(const char* modelPath, const char* tokenizerPath, int length) {
        if (!modelPath || !*modelPath || !tokenizerPath || !*tokenizerPath || length <= 2)
            throw Failure(1, "Model, tokenizer and sequence length are required.");
        sequence = length;
        auto status = tokenizer.Load(tokenizerPath);
        if (!status.ok()) throw Failure(2, status.ToString());
        if (tokenizer.bos_id() < 0 || tokenizer.eos_id() < 0 || tokenizer.pad_id() < 0)
            throw Failure(2, "Tokenizer requires BOS, EOS and PAD.");
        check(LiteRtCreateEnvironment(0, nullptr, &environment), 3, "environment");
        check(LiteRtCreateModelFromFile(environment, modelPath, &model), 4, "model");
        LiteRtOptions raw = nullptr;
        check(LiteRtCreateOptions(&raw), 5, "options");
        const std::unique_ptr<std::remove_pointer_t<LiteRtOptions>, decltype(&LiteRtDestroyOptions)>
            options(raw, LiteRtDestroyOptions);
        check(LiteRtSetOptionsHardwareAccelerators(raw, kLiteRtHwAcceleratorCpu), 5, "CPU");
        check(LiteRtCreateCompiledModel(environment, model, raw, &compiled), 5, "compile");
        LiteRtSignature signature = nullptr;
        check(LiteRtGetModelSignature(model, 0, &signature), 6, "signature");
        if (!signature) throw Failure(6, "Missing signature.");
        size_t inputs = 0, outputs = 0;
        check(LiteRtGetNumSignatureInputs(signature, &inputs), 6, "input count");
        check(LiteRtGetNumSignatureOutputs(signature, &outputs), 6, "output count");
        if (inputs != 1 || outputs != 1) throw Failure(6, "Expected one input and one output.");
        LiteRtTensor in = nullptr, out = nullptr;
        check(LiteRtGetSignatureInputTensorByIndex(signature, 0, &in), 6, "input tensor");
        check(LiteRtGetSignatureOutputTensorByIndex(signature, 0, &out), 6, "output tensor");
        if (!in || !out) throw Failure(6, "Missing tensor.");
        LiteRtRankedTensorType inType{}, outType{};
        check(LiteRtGetRankedTensorType(in, &inType), 6, "input type");
        check(LiteRtGetRankedTensorType(out, &outType), 6, "output type");
        if (inType.element_type != kLiteRtElementTypeInt32 || outType.element_type != kLiteRtElementTypeFloat32)
            throw Failure(6, "Expected Int32 input and Float32 output.");
        LiteRtTensorBufferRequirements inReq = nullptr, outReq = nullptr;
        check(LiteRtGetCompiledModelInputBufferRequirements(compiled, 0, 0, &inReq), 6, "input requirements");
        check(LiteRtGetCompiledModelOutputBufferRequirements(compiled, 0, 0, &outReq), 6, "output requirements");
        check(LiteRtCreateManagedTensorBufferFromRequirements(environment, &inType, inReq, &input), 6, "input buffer");
        check(LiteRtCreateManagedTensorBufferFromRequirements(environment, &outType, outReq, &output), 6, "output buffer");
        size_t inputSize = 0, outputSize = 0;
        check(LiteRtGetTensorBufferPackedSize(input, &inputSize), 6, "input size");
        check(LiteRtGetTensorBufferPackedSize(output, &outputSize), 6, "output size");
        if (inputSize != size_t(sequence) * sizeof(int32_t) || outputSize != 768 * sizeof(float))
            throw Failure(6, "Expected sequence-length input and 768-dimensional output.");
        dimension = 768;
    }
    void embed(const char* text, float* destination, size_t count) {
        if (!text || !*text || !destination || count != size_t(dimension))
            throw Failure(1, "Invalid embedding input or output size.");
        std::vector<int> encoded;
        auto status = tokenizer.Encode(std::string(text), &encoded);
        if (!status.ok()) throw Failure(7, status.ToString());
        if (encoded.size() > size_t(sequence - 2)) encoded.resize(sequence - 2);
        std::vector<int32_t> tokens;
        tokens.reserve(sequence);
        tokens.push_back(tokenizer.bos_id());
        tokens.insert(tokens.end(), encoded.begin(), encoded.end());
        tokens.push_back(tokenizer.eos_id());
        tokens.resize(sequence, tokenizer.pad_id());
        void* address = nullptr;
        check(LiteRtLockTensorBuffer(input, &address, kLiteRtTensorBufferLockModeWrite), 8, "lock input");
        if (!address) {
            LiteRtUnlockTensorBuffer(input);
            throw Failure(8, "Missing input buffer address.");
        }
        std::memcpy(address, tokens.data(), tokens.size() * sizeof(int32_t));
        check(LiteRtUnlockTensorBuffer(input), 8, "unlock input");
        check(LiteRtRunCompiledModel(compiled, 0, 1, &input, 1, &output), 8, "inference");
        address = nullptr;
        check(LiteRtLockTensorBuffer(output, &address, kLiteRtTensorBufferLockModeRead), 8, "lock output");
        if (!address) {
            LiteRtUnlockTensorBuffer(output);
            throw Failure(8, "Missing output buffer address.");
        }
        std::memcpy(destination, address, count * sizeof(float));
        check(LiteRtUnlockTensorBuffer(output), 8, "unlock output");
    }
};

PETEmbeddingCore* pet_embedding_create(const char* model, const char* tokenizer, int sequence,
                                      int* code, char* error, size_t capacity) {
    if (code) *code = 0;
    try {
        auto core = std::make_unique<PETEmbeddingCore>();
        core->prepare(model, tokenizer, sequence);
        return core.release();
    } catch (const Failure& e) {
        if (code) *code = e.code;
        message(e.what(), error, capacity);
    } catch (const std::exception& e) {
        if (code) *code = 8;
        message(e.what(), error, capacity);
    }
    return nullptr;
}
void pet_embedding_delete(PETEmbeddingCore* core) { delete core; }
int pet_embedding_dimension(const PETEmbeddingCore* core) { return core ? core->dimension : 0; }
int pet_embedding_compute(PETEmbeddingCore* core, const char* text, float* output, size_t count,
                          char* error, size_t capacity) {
    try {
        if (!core) throw Failure(1, "Embedding runtime is not prepared.");
        core->embed(text, output, count);
        return 0;
    } catch (const Failure& e) { message(e.what(), error, capacity); return e.code; }
    catch (const std::exception& e) { message(e.what(), error, capacity); return 8; }
}
