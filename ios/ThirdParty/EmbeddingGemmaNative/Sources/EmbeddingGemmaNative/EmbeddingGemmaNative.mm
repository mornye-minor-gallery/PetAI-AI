#import "EmbeddingGemmaNative.h"
#include "EmbeddingGemmaCore.h"
#include <vector>

NSErrorDomain const PETEmbeddingGemmaErrorDomain = @"com.mornye.EdgeLLM.EmbeddingGemma";

static void SetCoreError(NSError **error, int code, const char* text) {
    if (error) *error = [NSError errorWithDomain:PETEmbeddingGemmaErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:text]}];
}

@interface PETEmbeddingGemmaRunner () {
    PETEmbeddingCore* _core;
}
@end

@implementation PETEmbeddingGemmaRunner
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                             tokenizerPath:(NSString *)tokenizerPath
                            sequenceLength:(NSInteger)sequenceLength
                                     error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    char message[1024] = {};
    int code = 0;
    _core = pet_embedding_create(modelPath.UTF8String, tokenizerPath.UTF8String,
        (int)sequenceLength, &code, message, sizeof(message));
    if (!_core) { SetCoreError(error, code, message); return nil; }
    _dimension = pet_embedding_dimension(_core);
    _sequenceLength = sequenceLength;
    return self;
}
- (void)dealloc { pet_embedding_delete(_core); }
- (nullable NSData *)embeddingForText:(NSString *)text error:(NSError **)error {
    std::vector<float> output(_dimension);
    char message[1024] = {};
    int code = pet_embedding_compute(_core, text.UTF8String, output.data(), output.size(), message, sizeof(message));
    if (code) { SetCoreError(error, code, message); return nil; }
    return [NSData dataWithBytes:output.data() length:output.size() * sizeof(float)];
}
@end
