#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const PETEmbeddingGemmaErrorDomain;

typedef NS_ERROR_ENUM(PETEmbeddingGemmaErrorDomain, PETEmbeddingGemmaErrorCode) {
    PETEmbeddingGemmaErrorInvalidArgument = 1,
    PETEmbeddingGemmaErrorTokenizerLoad = 2,
    PETEmbeddingGemmaErrorLiteRTEnvironment = 3,
    PETEmbeddingGemmaErrorModelLoad = 4,
    PETEmbeddingGemmaErrorModelCompile = 5,
    PETEmbeddingGemmaErrorTensorContract = 6,
    PETEmbeddingGemmaErrorTokenization = 7,
    PETEmbeddingGemmaErrorInference = 8,
};

@interface PETEmbeddingGemmaRunner : NSObject

@property(nonatomic, readonly) NSInteger dimension;
@property(nonatomic, readonly) NSInteger sequenceLength;

- (instancetype)init NS_UNAVAILABLE;

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                             tokenizerPath:(NSString *)tokenizerPath
                            sequenceLength:(NSInteger)sequenceLength
                                     error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;

- (nullable NSData *)embeddingForText:(NSString *)text
                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
