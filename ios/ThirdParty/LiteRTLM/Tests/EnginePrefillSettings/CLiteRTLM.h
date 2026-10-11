#include <stdint.h>
typedef struct LiteRtLmEngineSettings LiteRtLmEngineSettings;
void litert_lm_engine_settings_set_prefill_chunk_size(LiteRtLmEngineSettings* settings, int chunk_size);
int test_prefill_chunk_size(void);
int test_setting_calls(void);
