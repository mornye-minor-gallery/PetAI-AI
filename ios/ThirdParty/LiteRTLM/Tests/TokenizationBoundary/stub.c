#include "CLiteRTLM.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct LiteRtLmTokenizeResult { size_t count; };
static int live_results;
static int calls;

LiteRtLmTokenizeResult* litert_lm_engine_tokenize(LiteRtLmEngine* engine, const char* text) {
    calls++;
    if (!engine || !text || strcmp(text, "native failure") == 0) return NULL;
    LiteRtLmTokenizeResult* result = malloc(sizeof(*result));
    // A fake native token count, deliberately unrelated to UTF-8 byte length.
    result->count = strcmp(text, "한글🌟") == 0 ? 7 :
        strcmp(text, "overflow") == 0 ? SIZE_MAX : 0;
    live_results++;
    return result;
}
size_t litert_lm_tokenize_result_get_num_tokens(const LiteRtLmTokenizeResult* result) { return result->count; }
void litert_lm_tokenize_result_delete(LiteRtLmTokenizeResult* result) { free(result); live_results--; }
int test_live_results(void) { return live_results; }
int test_tokenization_calls(void) { return calls; }

const int* litert_lm_tokenize_result_get_tokens(const LiteRtLmTokenizeResult* r) { static int ids[7] = {1,2,3,4,5,6,7}; return ids; }
