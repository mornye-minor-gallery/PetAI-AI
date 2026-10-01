#include "CLiteRTLM.h"
#include <stdlib.h>
#include <string.h>
struct LiteRtLmSession { int active; };
struct LiteRtLmSessionConfig { int unused; };
struct LiteRtLmSamplerParams { int unused; };
struct LiteRtLmInputData { char* text; };
struct LiteRtLmStreamChunk { const char* text; const char* error; bool final; };
static int created, rewinds, pending, start_error;
static int checkpoint_reads, checkpoint_writes, checkpoint_error;
int test_checkpoint_reads(void) { return checkpoint_reads; }
int test_checkpoint_writes(void) { return checkpoint_writes; }
void test_set_checkpoint_error(int code) { checkpoint_error = code; }
int litert_lm_session_transfer_state(LiteRtLmSession* s, LiteRtLmStateTransfer transfer, void* user_data, bool reading) {
 if (s->active) abort();
 if (checkpoint_error) return checkpoint_error;
 if (reading) checkpoint_reads++; else checkpoint_writes++;
 unsigned char value = 7;
 if (!transfer(&value, 1, user_data) || !transfer(NULL, 0, user_data)) return 15;
 return 0;
}
static char last_input[8192];
static char last_prefill[8192];
static int prefill_count;
int test_prefill_count(void) { return prefill_count; }
const char* test_prefill(void) { return last_prefill; }
int litert_lm_session_run_prefill(LiteRtLmSession* s,const LiteRtLmInputData* const* inputs,size_t n) {
 if (s->active || n!=1) abort();
 strcpy(last_prefill,inputs[0]->text); prefill_count++; return 0;
}
static LiteRtLmStreamCallback saved_callback;
static void* saved_data;
int test_created(void) { return created; }
int test_rewinds(void) { return rewinds; }
const char* test_input(void) { return last_input; }
void test_set_pending(int p) { pending=p; }
void test_set_start_error(int c) { start_error=c; }
LiteRtLmSessionConfig* litert_lm_session_config_create(void) { return calloc(1,sizeof(LiteRtLmSessionConfig)); }
void litert_lm_session_config_delete(LiteRtLmSessionConfig* p) { free(p); }
void litert_lm_session_config_set_max_output_tokens(LiteRtLmSessionConfig* p,int v) {}
void litert_lm_session_config_set_apply_prompt_template(LiteRtLmSessionConfig* p,bool v) {}
void litert_lm_session_config_set_sampler_params(LiteRtLmSessionConfig* p,const LiteRtLmSamplerParams* s) {}
LiteRtLmSamplerParams* litert_lm_sampler_params_create(LiteRtLmSamplerType t) { return calloc(1,sizeof(LiteRtLmSamplerParams)); }
void litert_lm_sampler_params_delete(LiteRtLmSamplerParams* p) { free(p); }
void litert_lm_sampler_params_set_top_k(LiteRtLmSamplerParams* p,int32_t v) {}
void litert_lm_sampler_params_set_top_p(LiteRtLmSamplerParams* p,float v) {}
void litert_lm_sampler_params_set_temperature(LiteRtLmSamplerParams* p,float v) {}
void litert_lm_sampler_params_set_seed(LiteRtLmSamplerParams* p,int32_t v) {}
LiteRtLmSession* litert_lm_engine_create_session(LiteRtLmEngine* e,LiteRtLmSessionConfig* c) { created++; return calloc(1,sizeof(LiteRtLmSession)); }
void litert_lm_session_delete(LiteRtLmSession* p) { if (p->active) abort(); free(p); }
int litert_lm_session_rewind_to_step(LiteRtLmSession* p,int step) { if (p->active || step!=0) abort(); rewinds++; return 0; }
LiteRtLmInputData* litert_lm_input_data_create(LiteRtLmInputDataType t,const void* data,size_t size) {
 LiteRtLmInputData* p=calloc(1,sizeof(*p)); p->text=strndup(data,size); return p;
}
void litert_lm_input_data_delete(LiteRtLmInputData* p) { free(p->text); free(p); }
int litert_lm_session_generate_content_stream(LiteRtLmSession* s,const LiteRtLmInputData* const* inputs,size_t n,LiteRtLmStreamCallback cb,void* data) {
 if(start_error) return start_error;
 strcpy(last_input,inputs[0]->text); s->active=1;
 if(pending) { saved_callback=cb; saved_data=data; return 0; }
 LiteRtLmStreamChunk text={"<|channel>thought\nsecret<channel|>안녕",NULL,false}; cb(data,&text);
 s->active=0; LiteRtLmStreamChunk end={NULL,strstr(last_input,"limit") ? "Max number of tokens reached." : NULL,true}; cb(data,&end); return 0;
}
void litert_lm_session_cancel_process(LiteRtLmSession* s) {
 if(s->active && saved_callback) { s->active=0; LiteRtLmStreamChunk end={NULL,"CANCELLED",true};
 LiteRtLmStreamCallback cb=saved_callback; saved_callback=NULL; cb(saved_data,&end); }
}
const char* litert_lm_stream_chunk_get_text(const LiteRtLmStreamChunk* c) { return c->text; }
const char* litert_lm_stream_chunk_get_error(const LiteRtLmStreamChunk* c) { return c->error; }
bool litert_lm_stream_chunk_is_final(const LiteRtLmStreamChunk* c) { return c->final; }
