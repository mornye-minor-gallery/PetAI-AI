#import "EmbeddingGemmaNative.h"

#import <CLiteRT/CLiteRT.h>
#import <CSentencePiece.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

// The tensor contract and token construction follow Google's Apache-2.0
// LiteRT semantic-similarity sample:
// google-ai-edge/litert-samples/compiled_model_api/semantic_similarity.

NSErrorDomain const PETEmbeddingGemmaErrorDomain =
    @"com.mornye.EdgeLLM.EmbeddingGemma";

namespace {

void SetError(
    NSError **error,
    PETEmbeddingGemmaErrorCode code,
    NSString *message
) {
    if (error == nullptr) {
        return;
    }
    *error = [NSError errorWithDomain:PETEmbeddingGemmaErrorDomain
                                 code:code
                             userInfo:@{
                                 NSLocalizedDescriptionKey: message
                             }];
}

bool CheckStatus(
    LiteRtStatus status,
    NSError **error,
    PETEmbeddingGemmaErrorCode code,
    NSString *operation
) {
    if (status == kLiteRtStatusOk) {
        return true;
    }
    SetError(
        error,
        code,
        [NSString stringWithFormat:@"%@ failed (LiteRT status=%d).",
                                   operation,
                                   status]
    );
    return false;
}

}  // namespace

@interface PETEmbeddingGemmaRunner () {
    sentencepiece::SentencePieceProcessor _tokenizer;
    LiteRtEnvironment _environment;
    LiteRtModel _model;
    LiteRtCompiledModel _compiledModel;
    LiteRtTensorBuffer _inputBuffer;
    LiteRtTensorBuffer _outputBuffer;
}
@end

@implementation PETEmbeddingGemmaRunner

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                             tokenizerPath:(NSString *)tokenizerPath
                            sequenceLength:(NSInteger)sequenceLength
                                     error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _environment = nullptr;
    _model = nullptr;
    _compiledModel = nullptr;
    _inputBuffer = nullptr;
    _outputBuffer = nullptr;
    _dimension = 0;
    _sequenceLength = sequenceLength;

    if (modelPath.length == 0 || tokenizerPath.length == 0 ||
        sequenceLength <= 2) {
        SetError(
            error,
            PETEmbeddingGemmaErrorInvalidArgument,
            @"Model path, tokenizer path, and a sequence length greater than two are required."
        );
        return nil;
    }

    auto tokenizerStatus = _tokenizer.Load(tokenizerPath.UTF8String);
    if (!tokenizerStatus.ok()) {
        SetError(
            error,
            PETEmbeddingGemmaErrorTokenizerLoad,
            [NSString stringWithFormat:
                @"Could not load sentencepiece.model: %s",
                tokenizerStatus.ToString().c_str()]
        );
        return nil;
    }
    if (_tokenizer.bos_id() < 0 || _tokenizer.eos_id() < 0 ||
        _tokenizer.pad_id() < 0) {
        SetError(
            error,
            PETEmbeddingGemmaErrorTokenizerLoad,
            @"The tokenizer must define BOS, EOS, and PAD token IDs."
        );
        return nil;
    }

    LiteRtStatus status =
        LiteRtCreateEnvironment(0, nullptr, &_environment);
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorLiteRTEnvironment,
            @"Creating the LiteRT environment"
        )) {
        return nil;
    }

    status = LiteRtCreateModelFromFile(
        _environment,
        modelPath.UTF8String,
        &_model
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorModelLoad,
            @"Loading the EmbeddingGemma model"
        )) {
        [self cleanup];
        return nil;
    }

    LiteRtOptions options = nullptr;
    status = LiteRtCreateOptions(&options);
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorModelCompile,
            @"Creating LiteRT compilation options"
        )) {
        [self cleanup];
        return nil;
    }
    status = LiteRtSetOptionsHardwareAccelerators(
        options,
        kLiteRtHwAcceleratorCpu
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorModelCompile,
            @"Selecting the LiteRT CPU backend"
        )) {
        LiteRtDestroyOptions(options);
        [self cleanup];
        return nil;
    }

    status = LiteRtCreateCompiledModel(
        _environment,
        _model,
        options,
        &_compiledModel
    );
    LiteRtDestroyOptions(options);
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorModelCompile,
            @"Compiling the EmbeddingGemma model"
        )) {
        [self cleanup];
        return nil;
    }

    if (![self prepareTensorBuffers:error]) {
        [self cleanup];
        return nil;
    }

    return self;
}

- (void)dealloc {
    [self cleanup];
}

- (nullable NSData *)embeddingForText:(NSString *)text
                                error:(NSError **)error {
    if (_compiledModel == nullptr ||
        _inputBuffer == nullptr ||
        _outputBuffer == nullptr) {
        SetError(
            error,
            PETEmbeddingGemmaErrorInvalidArgument,
            @"EmbeddingGemma is not prepared."
        );
        return nil;
    }
    if (text.length == 0) {
        SetError(
            error,
            PETEmbeddingGemmaErrorInvalidArgument,
            @"Embedding text must not be empty."
        );
        return nil;
    }

    std::vector<int> encodedTokens;
    auto tokenizerStatus = _tokenizer.Encode(
        std::string(text.UTF8String),
        &encodedTokens
    );
    if (!tokenizerStatus.ok()) {
        SetError(
            error,
            PETEmbeddingGemmaErrorTokenization,
            [NSString stringWithFormat:
                @"SentencePiece tokenization failed: %s",
                tokenizerStatus.ToString().c_str()]
        );
        return nil;
    }

    const size_t maximumContentLength =
        static_cast<size_t>(_sequenceLength - 2);
    if (encodedTokens.size() > maximumContentLength) {
        encodedTokens.resize(maximumContentLength);
    }

    std::vector<int32_t> inputTokens;
    inputTokens.reserve(static_cast<size_t>(_sequenceLength));
    inputTokens.push_back(static_cast<int32_t>(_tokenizer.bos_id()));
    for (int token : encodedTokens) {
        inputTokens.push_back(static_cast<int32_t>(token));
    }
    inputTokens.push_back(static_cast<int32_t>(_tokenizer.eos_id()));
    inputTokens.resize(
        static_cast<size_t>(_sequenceLength),
        static_cast<int32_t>(_tokenizer.pad_id())
    );

    size_t inputSize = 0;
    LiteRtStatus status =
        LiteRtGetTensorBufferPackedSize(_inputBuffer, &inputSize);
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Reading the input tensor size"
        )) {
        return nil;
    }
    const size_t tokenByteCount =
        inputTokens.size() * sizeof(int32_t);
    if (inputSize != tokenByteCount) {
        SetError(
            error,
            PETEmbeddingGemmaErrorTensorContract,
            [NSString stringWithFormat:
                @"The model expects %zu input bytes, but sequence length %ld produces %zu bytes.",
                inputSize,
                static_cast<long>(_sequenceLength),
                tokenByteCount]
        );
        return nil;
    }

    void *inputAddress = nullptr;
    status = LiteRtLockTensorBuffer(
        _inputBuffer,
        &inputAddress,
        kLiteRtTensorBufferLockModeWrite
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorInference,
            @"Locking the input tensor"
        )) {
        return nil;
    }
    if (inputAddress == nullptr) {
        LiteRtUnlockTensorBuffer(_inputBuffer);
        SetError(
            error,
            PETEmbeddingGemmaErrorInference,
            @"LiteRT returned an empty input tensor address."
        );
        return nil;
    }
    std::memcpy(inputAddress, inputTokens.data(), tokenByteCount);
    LiteRtUnlockTensorBuffer(_inputBuffer);

    status = LiteRtRunCompiledModel(
        _compiledModel,
        0,
        1,
        &_inputBuffer,
        1,
        &_outputBuffer
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorInference,
            @"Running EmbeddingGemma inference"
        )) {
        return nil;
    }

    void *outputAddress = nullptr;
    status = LiteRtLockTensorBuffer(
        _outputBuffer,
        &outputAddress,
        kLiteRtTensorBufferLockModeRead
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorInference,
            @"Locking the output tensor"
        )) {
        return nil;
    }
    if (outputAddress == nullptr) {
        LiteRtUnlockTensorBuffer(_outputBuffer);
        SetError(
            error,
            PETEmbeddingGemmaErrorInference,
            @"LiteRT returned an empty output tensor address."
        );
        return nil;
    }

    const NSUInteger outputByteCount =
        static_cast<NSUInteger>(_dimension) * sizeof(float);
    NSData *result = [NSData dataWithBytes:outputAddress
                                   length:outputByteCount];
    LiteRtUnlockTensorBuffer(_outputBuffer);
    return result;
}

- (BOOL)prepareTensorBuffers:(NSError **)error {
    LiteRtSignature signature = nullptr;
    LiteRtStatus status =
        LiteRtGetModelSignature(_model, 0, &signature);
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Reading the model signature"
        ) || signature == nullptr) {
        return NO;
    }

    size_t inputCount = 0;
    size_t outputCount = 0;
    status = LiteRtGetNumSignatureInputs(signature, &inputCount);
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Reading the model input count"
        )) {
        return NO;
    }
    status = LiteRtGetNumSignatureOutputs(signature, &outputCount);
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Reading the model output count"
        )) {
        return NO;
    }
    if (inputCount != 1 || outputCount != 1) {
        SetError(
            error,
            PETEmbeddingGemmaErrorTensorContract,
            [NSString stringWithFormat:
                @"EmbeddingGemma requires one input and one output tensor, but this model has %zu and %zu.",
                inputCount,
                outputCount]
        );
        return NO;
    }

    LiteRtTensor inputTensor = nullptr;
    LiteRtTensor outputTensor = nullptr;
    status = LiteRtGetSignatureInputTensorByIndex(
        signature,
        0,
        &inputTensor
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Reading the input tensor"
        ) || inputTensor == nullptr) {
        return NO;
    }
    status = LiteRtGetSignatureOutputTensorByIndex(
        signature,
        0,
        &outputTensor
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Reading the output tensor"
        ) || outputTensor == nullptr) {
        return NO;
    }

    LiteRtRankedTensorType inputType = {};
    LiteRtRankedTensorType outputType = {};
    status = LiteRtGetRankedTensorType(inputTensor, &inputType);
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Reading the input tensor type"
        )) {
        return NO;
    }
    status = LiteRtGetRankedTensorType(outputTensor, &outputType);
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Reading the output tensor type"
        )) {
        return NO;
    }
    if (inputType.element_type != kLiteRtElementTypeInt32 ||
        outputType.element_type != kLiteRtElementTypeFloat32) {
        SetError(
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"EmbeddingGemma requires an Int32 input tensor and a Float32 output tensor."
        );
        return NO;
    }

    LiteRtTensorBufferRequirements inputRequirements = nullptr;
    LiteRtTensorBufferRequirements outputRequirements = nullptr;
    status = LiteRtGetCompiledModelInputBufferRequirements(
        _compiledModel,
        0,
        0,
        &inputRequirements
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Reading the input buffer requirements"
        )) {
        return NO;
    }
    status = LiteRtGetCompiledModelOutputBufferRequirements(
        _compiledModel,
        0,
        0,
        &outputRequirements
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Reading the output buffer requirements"
        )) {
        return NO;
    }

    status = LiteRtCreateManagedTensorBufferFromRequirements(
        _environment,
        &inputType,
        inputRequirements,
        &_inputBuffer
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Creating the input buffer"
        )) {
        return NO;
    }
    status = LiteRtCreateManagedTensorBufferFromRequirements(
        _environment,
        &outputType,
        outputRequirements,
        &_outputBuffer
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Creating the output buffer"
        )) {
        return NO;
    }

    size_t outputSize = 0;
    status = LiteRtGetTensorBufferPackedSize(
        _outputBuffer,
        &outputSize
    );
    if (!CheckStatus(
            status,
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"Reading the output tensor size"
        )) {
        return NO;
    }
    if (outputSize == 0 || outputSize % sizeof(float) != 0) {
        SetError(
            error,
            PETEmbeddingGemmaErrorTensorContract,
            @"The output tensor does not contain a valid Float32 vector."
        );
        return NO;
    }

    _dimension = static_cast<NSInteger>(outputSize / sizeof(float));
    return YES;
}

- (void)cleanup {
    if (_inputBuffer != nullptr) {
        LiteRtDestroyTensorBuffer(_inputBuffer);
        _inputBuffer = nullptr;
    }
    if (_outputBuffer != nullptr) {
        LiteRtDestroyTensorBuffer(_outputBuffer);
        _outputBuffer = nullptr;
    }
    if (_compiledModel != nullptr) {
        LiteRtDestroyCompiledModel(_compiledModel);
        _compiledModel = nullptr;
    }
    if (_model != nullptr) {
        LiteRtDestroyModel(_model);
        _model = nullptr;
    }
    if (_environment != nullptr) {
        LiteRtDestroyEnvironment(_environment);
        _environment = nullptr;
    }
}

@end
