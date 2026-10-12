#include <memory>
#include <vector>

#include <gtest/gtest.h>
#include "runtime/executor/fake_llm_executor.h"
#include "runtime/framework/resource_management/resource_manager.h"
#include "runtime/util/convert_tensor_buffer.h"
#include "runtime/util/test_utils.h"

namespace litert::lm {
namespace {

// The real ResourceManager performs matching. This executor deliberately uses
// its stored cursor, like the compiled executor, not the hint in PrefillParams.
class CursorExecutor : public FakeLlmExecutor {
 public:
  CursorExecutor() : FakeLlmExecutor(100, {}, {}) {
    tokens.AddProcessedTokens({10});
    tokens.AddProcessedTokens({20});
    tokens.AddProcessedTokens({30});
  }
  absl::StatusOr<const ProcessedTokens*> GetProcessedTokens() const override {
    return &tokens;
  }
  absl::StatusOr<int> GetCurrentStep() const override {
    return cursor;
  }
  absl::Status SetCurrentStep(int step) override {
    ++set_calls;
    if (!set_status.ok()) return set_status;
    cursor = step;
    return absl::OkStatus();
  }
  absl::Status Prefill(const ExecutorInputs& inputs,
                       const ExecutorPrefillParams&) override {
    ++prefill_calls;
    prefill_cursor = cursor;
    auto tensor = inputs.GetTextTokenIdsPtr();
    if (!tensor.ok()) return tensor.status();
    auto ids = CopyFromTensorBuffer<int32_t>(**tensor);
    if (!ids) return absl::InternalError("test input buffer could not be read");
    received = *ids;
    return prefill_status;
  }
  absl::StatusOr<std::unique_ptr<LlmContext>> CloneContext() const override {
    ++clone_calls;
    auto state = std::make_unique<RuntimeState>();
    state->current_step = cursor;
    return std::make_unique<LlmContext>(nullptr,
        std::make_unique<RuntimeConfig>(), std::move(state));
  }
  ProcessedTokens tokens;
  int cursor = 0;
  int set_calls = 0;
  int prefill_calls = 0;
  int prefill_cursor = -1;
  mutable int clone_calls = 0;
  std::vector<int32_t> received;
  absl::Status set_status = absl::OkStatus();
  absl::Status prefill_status = absl::OkStatus();
};

class PrefixCursorTest : public ::testing::Test {
 protected:
  void SetUp() override {
    auto executor = std::make_unique<CursorExecutor>();
    native = executor.get();
    ASSERT_OK_AND_ASSIGN(auto settings, native->GetExecutorSettings());
    manager = std::make_unique<ResourceManager>(nullptr, std::move(executor),
        nullptr, nullptr, std::move(settings), nullptr);
    ASSERT_OK_AND_ASSIGN(auto created,
        manager->CreateContextHandler(SessionConfig::CreateDefault()));
    handler = std::move(created);
  }
  absl::Status Prefill(std::vector<int32_t> ids, int hint = -1) {
    auto buffer = CopyToTensorBuffer<int32_t>(absl::MakeConstSpan(ids),
                                            {1, static_cast<int>(ids.size())});
    if (!buffer) return absl::InternalError("test input buffer could not be created");
    auto locked = manager->AcquireExecutorWithContextHandler(handler);
    if (!locked.ok()) return locked.status();
    ExecutorPrefillParams params;
    params.SetCurrentStep(hint);
    return (*locked)->Prefill(
        ExecutorInputs(ExecutorTextData(std::move(*buffer)), std::nullopt,
                       std::nullopt), params);
  }
  CursorExecutor* native;
  std::unique_ptr<ResourceManager> manager;
  std::shared_ptr<ContextHandler> handler;
};

TEST_F(PrefixCursorTest, CompletePrefixAdvancesActualCursorBeforeSuffix) {
  ASSERT_TRUE(Prefill({10, 20, 30, 40}).ok());
  EXPECT_EQ(native->prefill_cursor, 3);
  EXPECT_EQ(native->received, (std::vector<int32_t>{40}));
  EXPECT_EQ(native->set_calls, 1);
  EXPECT_EQ(native->clone_calls, 0);
}

TEST_F(PrefixCursorTest, AlreadyAlignedCursorDoesNotInvokeRestrictedSetter) {
  native->cursor = 3;
  native->set_status = absl::InvalidArgumentError("backend rejects redundant seek");
  ASSERT_TRUE(Prefill({30, 40}, 2).ok());
  EXPECT_EQ(native->prefill_cursor, 3);
  EXPECT_EQ(native->set_calls, 0);
  EXPECT_EQ(native->received, (std::vector<int32_t>{40}));
}

TEST_F(PrefixCursorTest, FailedSeekDoesNotPrefillOrHideError) {
  native->set_status = absl::InternalError("seek failed");
  EXPECT_EQ(Prefill({10, 20, 30, 40}).message(), "seek failed");
  EXPECT_EQ(native->prefill_calls, 0);
  EXPECT_EQ(native->cursor, 0);
  native->set_status = absl::OkStatus();
  EXPECT_TRUE(Prefill({10, 20, 30, 40}).ok());
  EXPECT_EQ(native->prefill_cursor, 3);
}

TEST_F(PrefixCursorTest, SuffixFailureCanRetryFromRewind) {
  native->prefill_status = absl::InternalError("prefill failed");
  EXPECT_EQ(Prefill({10, 20, 30, 40}).message(), "prefill failed");
  EXPECT_EQ(native->prefill_cursor, 3);
  native->cursor = 0;
  native->prefill_status = absl::OkStatus();
  EXPECT_TRUE(Prefill({10, 20, 30, 40}).ok());
  EXPECT_EQ(native->prefill_cursor, 3);
}

TEST_F(PrefixCursorTest, CompleteInputHitDoesNotPrefill) {
  EXPECT_TRUE(Prefill({10, 20, 30}).ok());
  EXPECT_EQ(native->cursor, 3);
  EXPECT_EQ(native->prefill_calls, 0);
}

TEST_F(PrefixCursorTest, AppendWithoutRewindDoesNotSeek) {
  native->cursor = 3;
  EXPECT_TRUE(Prefill({40}).ok());
  EXPECT_EQ(native->prefill_cursor, 3);
  EXPECT_EQ(native->set_calls, 0);
}

TEST_F(PrefixCursorTest, PartialPrefixStillSeparatesContextAndSeeks) {
  EXPECT_TRUE(Prefill({10, 20, 99}).ok());
  EXPECT_EQ(native->prefill_cursor, 2);
  EXPECT_EQ(native->received, (std::vector<int32_t>{99}));
  EXPECT_EQ(native->clone_calls, 1);
  EXPECT_EQ(native->set_calls, 1);
}

}  // namespace
}  // namespace litert::lm
