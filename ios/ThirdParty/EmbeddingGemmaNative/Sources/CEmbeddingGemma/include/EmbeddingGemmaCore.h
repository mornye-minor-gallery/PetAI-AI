#ifndef PETAI_EMBEDDING_GEMMA_CORE_H
#define PETAI_EMBEDDING_GEMMA_CORE_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct PETEmbeddingCore PETEmbeddingCore;
PETEmbeddingCore* pet_embedding_create(const char* model, const char* tokenizer, int sequence,
                                      int* code, char* error, size_t capacity);
void pet_embedding_delete(PETEmbeddingCore* core);
int pet_embedding_dimension(const PETEmbeddingCore* core);
int pet_embedding_compute(PETEmbeddingCore* core, const char* text, float* output, size_t count,
                          char* error, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
