#include "CLiteRTLM.h"
static int value = -1;
static int calls = 0;
void litert_lm_engine_settings_set_prefill_chunk_size(LiteRtLmEngineSettings* settings, int size) { value = size; ++calls; }
int test_prefill_chunk_size(void) { return value; }
int test_setting_calls(void) { return calls; }
