# LiteRTLM iOS package

The Swift wrappers use the LiteRT-LM session APIs. Native builds pin public fork
revision [`939b09f5`](https://github.com/mornye-minor-gallery/LiteRT-LM/tree/939b09f5ac92974bb4a7df430d440c2b8780941e).
The fork contains exclusive CPU state transfer and the separate pending-token
prefill fix, based on upstream `a327b494f874a319605e6fd7e3439678daa4d07d`.
Native source and source-boundary tests belong to the public fork; Swift adapters,
file storage policy, and application integration tests belong to this package and
EdgeLLM. Upstream source comments are unchanged. The
[fork guide](https://github.com/mornye-minor-gallery/LiteRT-LM/blob/939b09f5ac92974bb4a7df430d440c2b8780941e/docs/PETAI_KV_CHECKPOINT.md)
lists the native changes and API contract.
Before adding a fork-specific operation, inspect existing upstream APIs for the
same capability, including ownership, locking, side effects and allocation behavior.
Reuse a suitable operation instead of exposing another path to the same state.

Prepare the native dependency from the repository root:

```bash
bash scripts/prepare-ios-native-dependencies.sh
```

Inspect the pinned source contract without downloading:

```bash
bash scripts/prepare-ios-native-dependencies.sh --print-config
```

The framework is stored under `ios/.artifacts/` and linked into this package at
`Artifacts/CLiteRTLM.xcframework`. Both paths remain outside version control.
The Unity iOS post-processor copies the prepared framework and these Swift
sources into the exported Xcode project.

PetAI keeps runtime-boundary extensions beside the upstream wrapper:

- native tokenizer-backed prompt measurement;
- native stream lifetime tracking used by cancellation and unload handling;
- full-prompt cached text sessions and the synchronous state-transfer C ABI.

The checkpoint ABI is built from source, not available in the official release
binary. Source archive, Bazel executable, and installed slice checksums
are recorded/validated by the preparation script. Builds are incremental;
compiled artifacts and model weights are never committed.

The same public repository also hosts `petai-ios-embedding-native-v1`, which
supplies LiteRT and SentencePiece frameworks through
`scripts/prepare-ios-embedding-dependencies.sh`. That release is independent of
the KV engine and must remain available while the app pins it. The
`petai-v0.14.0-topk-poc.1` release is a separate telemetry experiment, not a product
dependency. KV native sources are built from the pinned fork commit; there is no
KV prebuilt release in this distribution path.

## Full-prompt KV reuse

`Engine.createCachedSession` creates a CPU, Gemma 4 text-only adapter over the
existing Session C ABI. It keeps one native session alive and submits a complete
rendered request after `session_rewind_to_step(0)`. Native prefix matching skips
identical tokens and replaces the changed suffix. It does not clone sessions. GPU ringbuffer semantics are outside this adapter's scope.

`replaceInput` begins a new authoritative app turn: previous dynamic inputs are
not appended. The app supplies retained dialogue history. Additional sends before
`replaceInput` are retries and include the preceding visible response, rendered
with the official chat template. Sampling/output-limit changes replace the native
session; text changes do not. Reset/unload explicitly releases it.

Rendering uses an unprefilled Conversation solely for its model template. Never
query that temporary object's token count: `GetCurrentStep` acquires its executor
context and can cause a copy/context switch. Count the rendered text using the
engine tokenizer. The native BOS is stripped from the submitted text because a
fresh raw Session prepends it; it is included once in diagnostic tokenization.

Cancellation retains native ownership until the terminal callback. Rewind never
runs while generation is active. Gemma channel delimiters are buffered across
chunks; channel content is excluded from visible output and from retry history.
Token-limit termination returns available text, matching Conversation's default,
with `finishReason=token_limit`; other native errors propagate.

`matchingInputPrefixTokens` measures input/input token overlap, **not physical KV
hits**. Session C API does not expose current KV size. Native TTFT refers to the
first session turn, so use the runtime's monotonic `first_response_seconds` for
per-turn comparisons. No cache speedup or device memory safety follows from a
successful build or the stub tests.

Upstream API references:
- [Native CachedSession contract](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.17.1/runtime/core/cached_session.h)
- [Native prefix matching](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.17.1/runtime/framework/resource_management/resource_manager.cc)
- [Rewind semantics](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.17.1/runtime/core/session_advanced.cc)
- [BOS handling](https://github.com/google-ai-edge/LiteRT-LM/blob/v0.17.1/runtime/core/session_utils.cc)

Run `bash scripts/test-litertlm-cached-session.sh` from the repository root for
chunked channel parsing and native-boundary lifecycle tests. These use a C stub;
run the shared app runtime through `beolmuri-eval resource` for device evidence.

## File checkpoints

The app commits a completed visible recent turn before saving the latest native
CPU text-session cache. Cancellation, errors, tool replies and memory-caption
sessions never trigger a save. New requests, unload and cancellation cannot
interleave with the committed-turn checkpoint. Native task completion is checked
in addition to the Swift terminal callback.

The device-shared file is `Library/Caches/LiteRTLM/Session/latest.kv`, excluded
from backup and export. It is a disposable optimization, not a new history store.
There is one latest cache, not a cache archive. Recent turns and SQLite memories
remain authoritative. A kill during writing leaves the previous atomically
renamed file; startup removes the orphan temporary file.

Restore occurs when the first cached dialogue session is prepared, before its
full input is submitted. Native prefix matching still discards changed suffixes.
The app binds the file only to its cache compatibility version, model filename
and context capacity. It does not inspect filesystem identity or read model
contents at startup. Explicit language-model imports remove the cache before
replacing the model, including replacements with the same filename. Other model
replacement paths must also clear the cache when reusing a filename.
The single app compatibility version must change when the native state
representation or its interpretation becomes incompatible. Sampling settings and
output limits are not part of the identity. Changed prompts do not invalidate the
entire file because exact token-prefix matching handles them.

`KVCheckpointStore` in EdgeLLM owns the file, identity header, streamed SHA-256
payload check, temporary-file cleanup and atomic rename. Its POSIX reads/writes
operate directly on the supplied buffer; neither a whole-cache `Data` object nor
a model-sized autoreleased buffer chain is constructed.

## State-transfer contract

`litert_lm_session_transfer_state(session, transfer, user_data, reading)` performs
synchronous transfer with an idle, exclusively owned CPU session. The callback
receives a borrowed mutable pointer and length, in chunks no larger than 64 KiB.
On save, the caller reads those bytes without mutating them. On restore, the caller
fills the complete buffer. The pointer is valid only during the callback and must
not escape. The callback must not reenter the session or start inference.

`transfer(NULL, 0, user_data)` is the finalization call: the app validates the
payload digest and EOF before returning success on restore. Return `false` for
any transfer or finalization failure. The engine does not know filenames, model
identity, checksum algorithms, retention or atomic-file policies. It returns an
Abseil status code (`0` is success). Swift propagates the caller's I/O error unless
native cleanup failed (`10`), which poisons that session until engine recreation.

The caller waits until the final generation callback has returned before entering
this API. The engine additionally drains native tasks and rechecks authoritative
manager state under lock. Restore requires a fresh session. Only next-request
full-prompt reuse is supported, not resuming a half-generated answer. The Swift
adapter admits saves only after successful completion or the output-token limit;
the app decides which completed dialogue invokes it.

The binary state contains tensor layout and bytes, cursor, processed token IDs,
pending-token embeddings and sampler RNG. It is CPU/batch-one/in-place only, without
LoRA or speculative drafter. It has a format version, but is not a portable format.
GPU, cross-engine transfer, untrusted imports and schema migration are out of scope.

Buffers are transferred directly in bounded chunks, without cloning full KV.
A failed read clears the touched state and token metadata before cold prefill;
if clearing fails (status 10), inference is refused until engine reinitialization.
Failures are logged, not hidden. A failed write leaves the completed dialogue and
previous cache intact. Memory deletion and explicit conversation reset delete the
cache. No portable/untrusted cache import, GPU cache or format migration is supported.

Verification:

- `bash scripts/test-litertlm-cached-session.sh`: C-boundary admission tests.
- `swift test --package-path ios/EdgeLLM --filter KVCheckpointStoreTests`: storage/identity tests.
- `PETAI_LITERTLM_BAZEL=<bazel> bash scripts/test-litertlm-checkpoint-integration.sh <patched-native-source> <model> <new-result-directory>`:
  actual app composer + product checkpoint API in separate Mac CPU processes;
  ordinary, dynamic, recent-window boundary, cancelled and failed-turn fixtures,
  same-session continuation after save, plus corrupted/truncated-file,
  old-format and incompatible-identity recovery. The criterion is visible
  greedy-output equality, not a new bitwise-logit or device-speed claim.

Device latency, memory, cold-start responsiveness and kill/relaunch UX require
physical iPhone testing; Mac tests and an iOS build do not establish those results.

## Fork surface relative to the pinned upstream revision

The state-transfer extension touches 17 files: 8 existing source/header files, 5 new
implementation/helper files, and 4 build files. The prefill fix touches 4 files,
one of which is the same executor build file, for 20 distinct native files total.
Most existing headers only declare the forwarding operation; file policy is not
implemented at any native layer.

| Native file | Function or change |
| --- | --- |
| `c/engine.h`, `c/kv_checkpoint.cc` | `LiteRtLmStateTransfer`, `litert_lm_session_transfer_state` |
| `runtime/engine/engine.h` | `SessionInterface::TransferState` |
| `runtime/core/session_advanced.h`, `runtime/core/kv_checkpoint_session.cc` | `SessionAdvanced::TransferState`: fresh-state admission and task drain |
| `runtime/framework/resource_management/execution_manager.h` | `ExecutionManager::TransferState` |
| `runtime/framework/resource_management/threaded_execution_manager.h`, `runtime/framework/resource_management/kv_checkpoint_manager.cc` | `ThreadedExecutionManager::TransferState`: single owner, idle check and executor acquisition |
| `runtime/framework/resource_management/resource_manager.cc` | `LockedLlmExecutor::TransferState`: forwarding |
| `runtime/executor/llm_executor_base.h` | `LlmExecutorBase::TransferState` |
| `runtime/executor/llm_litert_compiled_model_executor.h`, `runtime/executor/kv_checkpoint.cc` | `LlmLiteRtCompiledModelExecutorBase::TransferState`: runtime metadata, existing KV buffer access and failed-import reset |
| `runtime/executor/kv_checkpoint_io.h` | `Io`: bounded callback transfer of values, vectors and tensor descriptors |
| `c/BUILD`, `runtime/core/BUILD`, `runtime/executor/BUILD`, `runtime/framework/resource_management/BUILD` | Compile/link added sources; Mac integration target |
| `runtime/executor/llm_litert_compiled_model_executor.cc` | `PrefillInternal`: prepare missing pending-token embeddings before writing float input |
| `runtime/executor/pending_prefill_embeddings.h` | `EnsurePendingPrefillEmbeddings`: resolve only missing embeddings |
| `runtime/executor/pending_prefill_embeddings_test.cc` | Ten focused prefill tests |

`DeepCopy`, `CloneContext`, `RestoreContext`, `Serialize` and `Load` are unchanged.
`LitertState` and its build file are also unchanged. The executor uses the existing
`GetStateBuffers` operation and checks that each input/output pair references the
same host buffer. That operation synchronizes signature shapes and duplicates
reference-counted handles, not the underlying KV data. Tensor names, element types,
dimensions and byte sizes are checked against the live buffers during import.
Native state format 2 and the app compatibility identifier reject earlier caches.
No KV clone is used by this path. The separate prefill fix is required when rewind
reconstructs an ID-only pending token for a model that consumes float embeddings;
it is not file persistence logic.
