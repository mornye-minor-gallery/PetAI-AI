#include <cassert>
#include <functional>
#include <map>
#include <string>
#include "runtime/executor/cpu_prefill_chunk.h"

int main() {
  using Runners = std::map<int, std::string, std::greater<int>>;
  const Runners all = {{1024, "prefill_1024"}, {128, "prefill_128"}};
  auto small = all;
  assert(litert::lm::LimitCpuPrefillRunners(small, 128));
  assert(small == Runners({{128, "prefill_128"}}));
  auto large = all;
  assert(litert::lm::LimitCpuPrefillRunners(large, 1024));
  assert(large == all);
  for (int limit : {0, -1}) {
    auto automatic = all;
    assert(litert::lm::LimitCpuPrefillRunners(automatic, limit));
    assert(automatic == all);
  }
  auto unavailable = all;
  assert(!litert::lm::LimitCpuPrefillRunners(unavailable, 64));
  assert(unavailable.empty());
}
