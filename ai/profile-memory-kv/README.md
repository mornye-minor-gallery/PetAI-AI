# Profile Memory KV smoke evaluation

This experiment checks one narrow question: can the deployment Gemma artifact
map a single Korean utterance to one allowed profile/preference key and value,
or abstain with `null`?

It intentionally does not evaluate roles, confidence, temporal validity,
multi-fact extraction, or reducer behavior.

## Contract

The model must emit exactly one of:

```json
{"preference.food":"떡볶이"}
```

```text
null
```

The parser accepts exactly one allowed key and one non-empty string value. It
rejects prose, Markdown fences, arrays, multiple fields, unknown keys, and
empty values.

## Run

```bash
LITERT_LM_PYTHON="${LITERT_LM_PYTHON:-$(uv tool dir)/litert-lm/bin/python}"
"$LITERT_LM_PYTHON" \
  ai/profile-memory-kv/evaluate_kv_extraction.py run \
  --prompt ai/profile-memory-kv/prompts/profile_kv_gate_v1.txt \
  --model-artifact ai/.artifacts/runtime-models/chat/gemma-e2b-it/gemma-4-E2B-it.litertlm \
  --backend cpu \
  --output-dir ai/profile-memory-kv/.artifacts/smoke-v1-gate-cpu
```

`profile_kv_v0.txt` is the minimal baseline. `profile_kv_gate_v1.txt` adds a
three-step speaker, assertion, and persistence gate before extraction.

The same 24-case dataset was reused to compare the two prompts. It is therefore
a development smoke set and must not be reported as deployment or
generalization performance.
