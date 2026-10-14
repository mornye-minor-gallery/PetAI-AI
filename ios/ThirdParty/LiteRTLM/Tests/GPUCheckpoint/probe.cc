// Standalone native probe. No product settings, user data, or CPU fallback.
#include "c/engine.h"
#include "c/error_reporter.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <unistd.h>

using Clock = std::chrono::steady_clock;
double Seconds(Clock::time_point start) {
  return std::chrono::duration<double>(Clock::now() - start).count();
}
void Check(bool ok, const char* stage) {
  if (ok) return;
  const char* detail = litert_lm_get_last_error_message();
  throw std::runtime_error(std::string(stage) + (detail ? ": " + std::string(detail) : ""));
}
std::string Read(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw std::runtime_error("cannot read fixture");
  return {std::istreambuf_iterator<char>(in), {}};
}
std::string Json(const std::string& text) {
  std::ostringstream out;
  out << '"';
  for (unsigned char c : text) {
    if (c == '"' || c == '\\') out << '\\' << c;
    else if (c < 32) {
      char escaped[7]; std::snprintf(escaped, sizeof(escaped), "\\u%04x", c); out << escaped;
    } else out << c;
  }
  return out.str() + '"';
}
struct FileTransfer {
  FILE* file;
  bool reading;
  static bool Run(void* data, size_t size, void* context) {
    auto& self = *static_cast<FileTransfer*>(context);
    if (!size) return self.reading
        ? std::fgetc(self.file) == EOF && !std::ferror(self.file)
        : std::fflush(self.file) == 0 && fsync(fileno(self.file)) == 0;
    return self.reading ? std::fread(data, 1, size, self.file) == size
                        : std::fwrite(data, 1, size, self.file) == size;
  }
};
struct Runtime {
  LiteRtLmEngine* engine = nullptr;
  LiteRtLmSession* session = nullptr;
  ~Runtime() {
    if (session) litert_lm_session_delete(session);
    if (engine) litert_lm_engine_delete(engine);
  }
  void Prefill(const std::string& text) {
    auto* input = litert_lm_input_data_create(kLiteRtLmInputDataTypeText, text.data(), text.size());
    Check(input != nullptr, "input");
    const LiteRtLmInputData* inputs[] = {input};
    int status = litert_lm_session_run_prefill(session, inputs, 1);
    litert_lm_input_data_delete(input);
    Check(status == 0, "prefill");
  }
  void Transfer(const std::string& path, bool reading) {
    // Use a temporary file and rename only after transfer + fsync succeeded.
    std::string working = reading ? path : path + ".partial";
    FILE* file = std::fopen(working.c_str(), reading ? "rb" : "wb");
    if (!file) throw std::runtime_error("checkpoint open failed");
    FileTransfer transfer{file, reading};
    int status = litert_lm_session_transfer_state(session, FileTransfer::Run, &transfer, reading);
    bool closed = std::fclose(file) == 0;
    if (status || !closed) {
      if (!reading) std::remove(working.c_str());
      // Exit this process; never reuse an engine after a partial GPU restore.
      const char* detail = litert_lm_get_last_error_message();
      throw std::runtime_error("checkpoint transfer failed: status=" + std::to_string(status) +
                               (detail ? ": " + std::string(detail) : ""));
    }
    if (!reading && std::rename(working.c_str(), path.c_str()))
      throw std::runtime_error("checkpoint rename failed");
  }
};

extern "C" int run_probe(int argc, char** argv) {
  try {
    if (argc != 7) throw std::runtime_error("usage: probe cpu|gpu baseline|save|restore|cold MODEL LIBDIR RUN_DIR CONTEXT");
    std::string backend = argv[1], mode = argv[2], dir = argv[5];
    if (backend != "cpu" && backend != "gpu") throw std::runtime_error("invalid backend");
    if (mode != "baseline" && mode != "save" && mode != "restore" && mode != "cold")
      throw std::runtime_error("invalid mode");
    const std::string prefix = Read(dir + "/prefix.txt"), full = Read(dir + "/followup.txt");
    if (prefix.empty() || full.empty())
      throw std::runtime_error("inputs must not be empty");
    Runtime runtime;
    std::cout << "STAGE initialize backend=" << backend << std::endl;
    auto start = Clock::now();
    auto* settings = litert_lm_engine_settings_create(argv[3], backend.c_str(), nullptr, nullptr);
    Check(settings != nullptr, "settings");
    litert_lm_engine_settings_set_max_num_tokens(settings, std::stoi(argv[6]));
    litert_lm_engine_settings_set_num_threads(settings, 4);
    litert_lm_engine_settings_set_cache_dir(settings, (dir + "/compile-cache").c_str());
    litert_lm_engine_settings_set_litert_dispatch_lib_dir(settings, argv[4]);
    litert_lm_engine_settings_enable_benchmark(settings);
    litert_lm_engine_settings_set_enable_speculative_decoding(settings, false);
    if (backend == "cpu") litert_lm_engine_settings_set_prefill_chunk_size(settings, 128);
    runtime.engine = litert_lm_engine_create(settings);
    litert_lm_engine_settings_delete(settings);
    Check(runtime.engine != nullptr, "engine");
    double initialization = Seconds(start);
    auto* config = litert_lm_session_config_create();
    Check(config != nullptr, "config");
    litert_lm_session_config_set_apply_prompt_template(config, false);
    const char* requested_limit = std::getenv("PETAI_PROBE_OUTPUT_LIMIT");
    int output_limit = requested_limit ? std::stoi(requested_limit) : 32;
    if (output_limit < 1 || output_limit > 384) throw std::runtime_error("invalid output limit");
    litert_lm_session_config_set_max_output_tokens(config, output_limit);
    // Match CachedSession: TOP_P with k=1, p=1, temperature=0. The advertised
    // Greedy and TopK enums are not implemented by this pinned CPU sampler.
    auto* sampler = litert_lm_sampler_params_create(kLiteRtLmSamplerTypeTopP);
    Check(sampler != nullptr, "sampler");
    litert_lm_sampler_params_set_top_k(sampler, 1);
    litert_lm_sampler_params_set_top_p(sampler, 1);
    litert_lm_sampler_params_set_temperature(sampler, 0);
    litert_lm_sampler_params_set_seed(sampler, 42);
    litert_lm_session_config_set_sampler_params(config, sampler);
    runtime.session = litert_lm_engine_create_session(runtime.engine, config);
    litert_lm_sampler_params_delete(sampler);
    litert_lm_session_config_delete(config);
    Check(runtime.session != nullptr, "session");
    double transfer_seconds = 0;
    if (mode == "restore") {
      std::cout << "STAGE restore" << std::endl;
      start = Clock::now(); runtime.Transfer(dir + "/checkpoint.bin", true);
      transfer_seconds = Seconds(start);
    } else if (mode != "cold") {
      std::cout << "STAGE prefix" << std::endl;
      runtime.Prefill(prefix);
      if (mode == "save") {
        std::cout << "STAGE save" << std::endl;
        start = Clock::now(); runtime.Transfer(dir + "/checkpoint.bin", false);
        transfer_seconds = Seconds(start);
      }
    }
    std::cout << "STAGE followup" << std::endl;
    if (mode != "cold") Check(litert_lm_session_rewind_to_step(runtime.session, 0) == 0, "rewind");
    start = Clock::now(); runtime.Prefill(full);
    double prefill_seconds = Seconds(start);
    std::cout << "STAGE decode" << std::endl;
    start = Clock::now();
    auto* responses = litert_lm_session_run_decode(runtime.session);
    Check(responses != nullptr, "decode");
    const char* response = litert_lm_responses_get_response_text_at(responses, 0);
    std::string output = response ? response : "";
    litert_lm_responses_delete(responses);
    double decode_seconds = Seconds(start);
    Check(!output.empty(), "empty output");
    struct rusage usage{}; getrusage(RUSAGE_SELF, &usage);
    long peak_rss_kib = usage.ru_maxrss;
#if defined(__APPLE__)
    peak_rss_kib /= 1024;  // Darwin reports bytes; Android reports KiB.
#endif
    std::cout << "RESULT {\"backend\":" << Json(backend) << ",\"mode\":" << Json(mode)
              << ",\"output\":" << Json(output) << ",\"initialization_seconds\":" << initialization
              << ",\"transfer_seconds\":" << transfer_seconds << ",\"prefill_seconds\":" << prefill_seconds
              << ",\"decode_seconds\":" << decode_seconds << ",\"peak_rss_kib\":" << peak_rss_kib << "}" << std::endl;
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAILED " << error.what() << std::endl;
    return 1;
  }
}
