#include <stddef.h>
typedef struct LiteRtLmEngine LiteRtLmEngine;
typedef struct LiteRtLmTokenizeResult LiteRtLmTokenizeResult;
LiteRtLmTokenizeResult* litert_lm_engine_tokenize(LiteRtLmEngine*, const char*);
size_t litert_lm_tokenize_result_get_num_tokens(const LiteRtLmTokenizeResult*);
void litert_lm_tokenize_result_delete(LiteRtLmTokenizeResult*);
int test_live_results(void);
int test_tokenization_calls(void);
