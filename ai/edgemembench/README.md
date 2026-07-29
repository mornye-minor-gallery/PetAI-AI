# EdgeMemBench v0

EdgeMemBench v0 is a repository-local benchmark for the first four memory
capabilities needed by EdgeMem.

| Axis | Capability | Cases | Source |
| --- | --- | ---: | --- |
| A | Decide whether a user utterance contains a preference and/or an event | 300 | PetAI synthetic frozen test sets |
| B | Retrieve one relevant user memory | 92 | LongMemEval-S cleaned |
| C | Prefer the current fact when user memories conflict | 72 | LongMemEval-S cleaned |
| D | Abstain when the required memory is absent | 30 | LongMemEval-S cleaned |

Axes E (multi-memory composition) and F (persona-level personalization) are
explicitly outside v0. Axis A and axes B-D are also evaluated separately:
A measures memory admission, while B-D start from an already constructed
user-only history and measure downstream memory behavior.

## Build the benchmark

Python 3.11 or later is recommended. The generator uses only the standard
library.

```bash
cd ai/edgemembench

python3 prepare.py import-storage \
  --test /absolute/path/to/test.jsonl \
  --challenge /absolute/path/to/synthetic_challenge.jsonl

python3 prepare.py build \
  --source /absolute/path/to/longmemeval_s_cleaned.json

python3 prepare.py validate
python3 -m unittest discover -s tests -v
```

`import-storage` verifies the pinned source hashes before replacing the
versioned `data/storage_decision.jsonl`. The generated LongMemEval-derived
artifacts are written to `.artifacts/v0/` and intentionally ignored by Git.
The 265 MB upstream source file is never copied into this repository.

If `--source` is omitted, `build` downloads the pinned official file into the
ignored `.artifacts/cache/` directory.

## Artifact contract

Every generated JSONL record has a stable `case_id`, an `axis`, a `task`, an
`expected` object, and source provenance.

- A contains one utterance and the expected `P/E` booleans plus `N/P/E/B`.
- B and C contain user-only sessions, gold evidence turn IDs, and the expected
  answer.
- D contains user-only sessions and `expected_abstention: true`; it has no
  complete gold answer evidence. Some source cases retain
  `partial_evidence_turn_ids` so systems can be tested against tempting but
  insufficient evidence.

`artifact_manifest.json` records counts and SHA-256 hashes for deterministic
handoff. Validation fails if canonical counts change, assistant messages leak
into the history, gold evidence disappears, or an artifact hash differs.

## Intended metrics

- A: exact two-axis accuracy, per-axis F1, and N/P/E/B confusion matrix.
- B: evidence Hit@K/MRR and answer accuracy.
- C: latest-state accuracy and gold-evidence rank.
- D: abstention accuracy and false-answer rate.

The dataset adapter does not run Gemma, embeddings, retrieval, or iPhone code.
Those systems consume the generated cases in later evaluation runners.
