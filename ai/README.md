# PetAI AI workspace

`ai/` contains reproducible, product-specific model and memory evaluation
code for the PetAI monorepo.

Current experiment areas:

- `memory-classifier/`: Preference/Event admission and memory-header evaluation
- `edgemembench/`: retrieval, temporal resolution, and abstention benchmarks
- `profile-memory-kv/`: minimal closed-key profile/preference extraction smoke
- `mrbench-custom/`: Korean Elena persona prompting and raw AutoJudge benchmark
- `facetroutebench/`: Gemma vs. EmbeddingGemma 20-route authoring and evaluation harness

Commit:

- evaluation runners and deterministic data preparation scripts
- prompts, manifests, tests, and small frozen evaluation datasets
- compact result summaries needed to review or reproduce a decision

Do not commit:

- model or tokenizer weights
- virtual environments and tool caches
- downloaded upstream datasets
- extracted embeddings, checkpoints, or per-run raw artifacts

Generated or downloaded files must stay under the experiment's ignored
`.artifacts/` directory. Model and tokenizer paths are provided explicitly at
runtime, and committed manifests record their identifiers or SHA-256 values
without copying the files into Git.

## Runtime tuning research plan

The app's current product defaults live in
`SLMConfiguration.production`; call sites should not duplicate them. The
initial memory configuration retrieves up to 10 observations, filters cosine
similarity below `0.3`, and gives recalled memory a 10,000-unit prompt budget.
Generation is capped at 4,096 output tokens.

These values are MVP settings, not finalized research findings:

1. Compare Top-3, Top-5, and Top-10 with the same EdgeMemBench cases, recording
   retrieval quality, actual prefill tokens, TTFT, and total latency.
2. Replace the current deterministic UTF-8 byte proxy for the 10K memory budget
   with the exact Gemma tokenizer count once the runtime exposes pre-generation
   tokenization. Until then, the setting bounds memory text but must not be
   reported as an exact token count.
3. Calibrate the provisional `0.3` similarity floor on a separate calibration
   split. Report threshold sweeps before freezing an operating point; do not
   tune and claim performance on the same test split.
4. When reranking is introduced, split the single recall limit into a larger
   `denseCandidateLimit` and a smaller `promptMemoryLimit` instead of silently
   changing the meaning of Top-K.
