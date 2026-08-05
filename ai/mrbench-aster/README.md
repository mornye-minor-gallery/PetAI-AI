# MRBench-Aster

MRBench-Aster is a repository-local Korean benchmark for comparing persona
prompt representations on the deployment Gemma 4 E2B IT artifact. It adapts
the memory-selection, boundary, and enactment ideas from MRBench to PetAI's
original character Aster.

It is a reduced, Korean, Aster-specific adaptation rather than an official
reproduction of MRBench:

- `MA-SI` and `MA-AF` are reported as `N/A` because Aster is an original
  character without pretrained name priors or a book-grounded gold response;
- the dataset follows the paper's MS/MB transformations and ME re-scoring, but
  is reduced from 200 instances per ability and language to 30 MS and 30 MB
  Korean instances;
- the judge is the pinned Codex CLI model rather than GPT-4.1-mini, and scores
  are not calibrated to a human scale.

Reference paper:
[Memory-Driven Role-Playing: Evaluation and Enhancement of Persona Knowledge Utilization in LLMs](https://arxiv.org/abs/2603.19313)
(arXiv:2603.19313).

## Metrics

| Group | Metric | Question |
| --- | --- | --- |
| Situational persona | `MS-FA` | Does the reply activate the correct scene facet? |
| Situational persona | `MS-FU` | Do scene facets improve the reply over a facetless persona? |
| Knowledge boundary | `MB-AL` | Does the reply avoid inventing inaccessible information? |
| Knowledge boundary | `MB-CR` | Does the reply handle uncertainty in character? |
| Enactment | `ME-MAC` | Is the reply coherent with persona memory and dialogue? |
| Enactment | `ME-HLE` | Is the reply natural, conversational, and character-like? |

These six metric names and ability assignments follow MREval. The local Korean
instances and raw judge scores are not directly comparable to the paper's
human-calibrated English/Chinese scores.

## Evaluation-set construction

`data/evaluation.jsonl` contains 60 single-response continuation items:

- 30 `MS` items: five fixed-STM scenes for each of Aster's six scene facets;
- 30 `MB` items: 15 future-timeline and 15 out-of-domain final-turn
  perturbations, each retaining its minimally changed in-scope anchor;
- 30 balanced `ME` selections: 15 MS and 15 MB outputs are re-scored without a
  new generation condition.

Narrative and pet-raising daily-life domains each contribute 30 items. MS keeps
the dialogue fixed and varies only `full`, `no_scene`, and `anti` LTM. MB keeps
the `full` LTM and dialogue prefix fixed while changing the final interlocutor
turn from the recorded in-scope anchor to the out-of-scope query. This follows
the paper's context-reuse and minimal-perturbation principle.

## Repository contract

Committed:

- persona source and the twelve controlled persona prompt variants;
- 60 versioned evaluation cases that remain draft until planning review;
- metric rubrics, schema validation, runners, and tests;
- compact result summaries after a decision is reproduced.

Ignored under `.artifacts/`:

- raw Gemma generations and judge responses;
- run manifests and latency logs;
- temporary caches or downloaded model files.

The deployment model remains pinned by `ai/models/runtime-models.json`. Never
copy a `.litertlm` model into this directory.

## Prompt conditions

Each persona representation has three controlled memory conditions:

```text
prompts/
├── base/{full,no_scene,anti}.md
├── card/{full,no_scene,anti}.md
├── mrprompt/{full,no_scene,anti}.md
└── compact/{full,no_scene,anti}.md
```

- `full`: canonical core traits plus situational facets;
- `no_scene`: the same identity and core traits without situational facets;
- `anti`: the same identity and core traits with counter-facets.

`compact` preserves the canonical Aster facts and behaviors while removing
MRPrompt's field-by-field facet metadata. Its short, ordered rules are an
on-device prompt variant; `mrprompt` remains unchanged as the comparison
baseline.

Rapid full-prompt experiments live under `prompts/candidates/`. Each filename
is an immutable candidate ID with one explicit prompting hypothesis. These
candidates are screened with the fixed dataset but do not receive controlled
`no_scene` and `anti` variants until one is promoted into the main format
matrix.

`--inject-facet-hint` and `--inject-facet-card` are diagnostic oracles, not
deployable scores. They add either the gold MS facet ID or its static behavior
card to measure whether scene selection or scene enactment is the current
bottleneck. Results using them are labeled `evaluation_oracle_id` or
`evaluation_oracle_card` and are never ordinary prompt-only performance.

`run_routed_generation.py` removes the oracle by asking the deployment model
for one scene label in a short first pass, then appending only that scene's
behavior card for the response pass. It records route accuracy and separates
route latency from response latency. This is a deployable architecture
candidate, unlike the oracle modes.

The frozen `0.32.0-draft` candidate adds a boundary pass before scene routing:

```text
user turn -> BOUNDARY / IN_SCOPE
  BOUNDARY -> boundary card -> response
  IN_SCOPE -> scene label -> scene card -> response
```

The exact selected files, hashes, runtime settings, and known failures are in
`prompts/final/selection-v0.32.json`. Its status is deliberately
`frozen_best_found_mvp_candidate_not_gold`; it is the best reproduced MVP
tradeoff found in this run, not a claim of research-gold generalization.

Normal product-quality scoring uses `full`. `MS-FA` compares `full` with
`anti`, and `MS-FU` compares `full` with `no_scene` under the same dialogue.

## Validate committed inputs

Python 3.11 or later is sufficient; the harness uses only the standard
library.

```bash
python3 ai/mrbench-aster/validate.py
python3 -m unittest discover -s ai/mrbench-aster/tests -v
```

## Run Gemma generation

Start the local LiteRT-LM OpenAI-compatible server separately. Then run each
controlled condition needed by the evaluation. The exact deployment
`.litertlm` artifact is the final source of truth.

```bash
python3 ai/mrbench-aster/run_generation.py \
  --base-url http://127.0.0.1:9379/v1 \
  --model gemma-4-e2b-it \
  --model-artifact ai/.artifacts/runtime-models/chat/gemma-e2b-it/gemma-4-E2B-it.litertlm \
  --runtime litert-lm \
  --backend cpu \
  --persona-format mrprompt \
  --memory-condition full \
  --output-dir ai/mrbench-aster/.artifacts/gemma-mrprompt-full
```

Repeat with `no_scene` and `anti` for `MS-FU` and `MS-FA`, and with `base`
and `card` when comparing persona formats. Output directories are never
overwritten. `full` prepares all 60 MS/MB cases; `no_scene` and `anti` prepare
only the 30 MS cases because MB keeps the full LTM fixed.

Run an immutable experimental candidate with an explicit ID:

```bash
python3 ai/mrbench-aster/run_generation.py \
  --base-url http://127.0.0.1:9379/v1 \
  --model gemma4-e2b,gpu \
  --runtime litert-lm \
  --backend gpu \
  --prompt-file ai/mrbench-aster/prompts/candidates/v02-rules-first.md \
  --prompt-id v02-rules-first \
  --memory-condition full \
  --output-dir ai/mrbench-aster/.artifacts/gemma-v02-rules-first
```

## Run the automatic judge

The default judge backend uses the signed-in Codex CLI subscription instead of
an API key. The pinned default is `gpt-5.6-luna` with low reasoning effort.
Each run records the exact model, reasoning effort, Codex CLI version, sandbox,
and output-schema hash. This avoids separate metered API calls but still uses
the account's Codex plan quota.

```bash
python3 ai/mrbench-aster/run_judge.py \
  --generation-dir ai/mrbench-aster/.artifacts/gemma-mrprompt-full \
  --comparison-dir ai/mrbench-aster/.artifacts/gemma-mrprompt-no-scene \
  --metric MS-FU \
  --output-dir ai/mrbench-aster/.artifacts/judge-mrprompt-fu
```

The adapter runs `codex exec` ephemerally, ignores mutable user configuration
and repository instructions, uses a read-only sandbox, and constrains the last
message with the committed JSON schema. To use an OpenAI-compatible judge
instead, explicitly select it and keep credentials only in
`MRBENCH_ASTER_JUDGE_API_KEY`:

```bash
python3 ai/mrbench-aster/run_judge.py \
  --backend openai-compatible \
  --base-url https://judge.example/v1 \
  --model frontier-judge-model \
  --generation-dir ai/mrbench-aster/.artifacts/gemma-mrprompt-full \
  --metric ME-HLE \
  --output-dir ai/mrbench-aster/.artifacts/judge-mrprompt-hle
```

The judge temperature is fixed to `0`. Reports must label these values as
`MRBench-Aster AutoJudge Raw Score`; there is no human calibration.
Use `--ability MS` or `--ability MB` when two generation runs cover different
ability subsets and the comparison must keep the selected cases identical.

Do not rank prompt candidates by independent absolute Luna scores. Re-scoring
identical replies changed individual scores by as much as three points in this
study. Candidate comparisons instead use `run_pairwise_judge.py`, which places
both replies in one blinded request, reverses A/B order across three repeats,
and reduces results by case-level majority vote. Absolute scores remain
diagnostic only.

## Frozen MVP candidate

The final architecture, measured results, overfitting audit, and reproduction
command are recorded in `RESULTS.md`. The short machine-readable selection is
`prompts/final/selection-v0.32.json`.

## Summarize

```bash
python3 ai/mrbench-aster/summarize.py \
  --input ai/mrbench-aster/.artifacts/judge-mrprompt-hle/results.jsonl \
  --input ai/mrbench-aster/.artifacts/judge-mrprompt-fu/results.jsonl \
  --output-dir ai/mrbench-aster/.artifacts/summary
```

Mac runs provide quality/regression evidence. Device latency, memory, thermal,
battery, and sustained-load behavior remain `UNVERIFIED` until measured on the
physical target iPhone.
