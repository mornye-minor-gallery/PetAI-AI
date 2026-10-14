#include "runtime/executor/litert/checkpoint_buffers.h"
#include <cassert>
#include <iostream>
#include <map>
#include <optional>

struct Buffer { int value; };
struct Slot { Buffer buffer; };

int main() {
  using namespace litert::lm::checkpoint;
  std::map<std::string, Slot> first{{"v", {{2}}}, {"k", {{1}}}};
  std::optional<std::map<std::string, Slot>> second;
  auto one = BankPointers(first, second);
  assert(one.size() == 2 && one[0].first == "bank1/k");
  assert(one[0].second == &first.at("k").buffer);
  second.emplace(first);
  second->at("k").buffer.value = 9;
  auto two = BankPointers(first, second);
  assert(two.size() == 4 && two[2].first == "bank2/k");
  assert(two[2].second->value == 9);
  // Export is a read-only view; it neither swaps banks nor duplicates storage.
  assert(BankPointers(first, second) == two);
  two[2].second->value = 11;
  assert(first.at("k").buffer.value == 1);
  assert(second->at("k").buffer.value == 11);

  for (bool lock_ok : {false, true}) {
    for (bool io_ok : {false, true}) {
      for (bool unlock_ok : {false, true}) {
        int locks = 0, transfers = 0, unlocks = 0;
        auto result = TransferMapped(
            [&] { ++locks; return lock_ok; },
            [&] { ++transfers; return io_ok; },
            [&] { ++unlocks; return unlock_ok; });
        assert(locks == 1 && transfers == int(lock_ok) && unlocks == int(lock_ok));
        auto expected = !lock_ok ? TransferResult::kLockFailed
            : !unlock_ok ? TransferResult::kUnlockFailed
            : !io_ok ? TransferResult::kTransferFailed : TransferResult::kOk;
        assert(result == expected);
      }
    }
  }
  std::cout << "PASS bank views and 8 mapping failure combinations\n";
}
