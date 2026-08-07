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
