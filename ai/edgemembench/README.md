# EdgeMemBench v0

EdgeMemBench v0 is a repository-local benchmark for the first four memory
capabilities needed by EdgeMem.

| Axis | Capability | Cases | Source |
| --- | --- | ---: | --- |
| A | Decide whether a user utterance contains a preference and/or an event | 300 | PetAI synthetic frozen test sets |
| B | Retrieve relevant user memory evidence | 92 | LongMemEval-S cleaned |
| C | Retrieve the fact(s) requested by a temporal question | 72 | LongMemEval-S cleaned + manual review |
| D | Abstain when the required memory is absent | 30 | LongMemEval-S cleaned |

The dataset contains **494 cases** in total. Axes E (multi-memory composition)
and F (persona-level personalization) are
explicitly outside v0. Axis A and axes B-D are also evaluated separately:
A measures memory admission, while B-D start from an already constructed
user-only history and measure downstream memory behavior. A B-D runner must
therefore bypass memory admission and inject every user turn as an existing
memory observation.

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
- C additionally contains a manually reviewed temporal subtype and a
  `target`/`competing`/`context` evidence partition.
- D contains user-only sessions and `expected_abstention: true`; it has no
  complete gold answer evidence. Some source cases retain
  `partial_evidence_turn_ids` so systems can be tested against tempting but
  insufficient evidence.

`artifact_manifest.json` records counts and SHA-256 hashes for deterministic
handoff. The expected B-D hashes are also pinned in
`benchmark_manifest.json`, so changing adapter selection or normalization
cannot silently create a different benchmark with the same counts.

Validation also checks the benchmark/version/profile contract, required
record fields and types, unique session/turn IDs, timestamp format and order,
answer-session references, user-only history, and axis-specific evidence
partitions.

### Axis B: multiple gold memories

B is not limited to exactly one gold turn: 81 cases contain one gold turn,
8 contain two, and 3 contain three. Its scoring contract is:

- **any-gold Hit@K**: successful when at least one gold turn appears in top K;
- **best-gold MRR**: reciprocal rank of the highest-ranked gold turn;
- **gold Recall@K**: fraction of all gold turns recovered in top K.

### Axis C: manually reviewed temporal targets

C does not assume that the latest evidence timestamp is always the answer.
Each of the 72 source cases is reviewed in
`data/knowledge_update_annotations.jsonl`, which is pinned by SHA-256. The
generated artifact resolves its one-based source ordinals into exact turn IDs:

- `target_evidence_turn_ids`: directly answer the question, or are all
  required for a comparison or calculation;
- `competing_evidence_turn_ids`: contain a conflicting value from another
  state;
- `context_evidence_turn_ids`: are related context but do not answer the
  question.

The scored temporal subtypes are:

- `current_state`: 54 cases asking for the current or updated state;
- `historical_state`: 6 cases explicitly asking for an older state;
- `multi_state`: 7 cases requiring both states for comparison or inference;
- `single_state`: 2 cases with one answer-bearing state and no conflict.

Three additional source cases remain in the 72-record artifact with
`evaluation_status: excluded`: one has contradictory source chronology, one
has an ambiguous temporal reference, and one names an entity not present in
its update evidence. They retain their evidence and review rationale for
auditability but do not contribute to aggregate retrieval scores.

Report target Hit@K, best-target MRR, target Recall@K, and
target-before-competing where a competing state exists. The current product
`MemoryPromptBuilder` sends only memory text, not `occurredAt`, so a reader
still cannot resolve every temporal relation. Record this as a separate
product representation failure; a future timestamp-aware prompt is an
ablation, not the same baseline.

### Axis D: two abstention conditions

D separates:

- `partial_evidence`: related but insufficient evidence exists (9 cases);
- `absent_evidence`: no related evidence exists (21 cases).

Retrieval evaluation reports query-level AUROC by comparing B/C top-1 scores
with D top-1 scores, plus a threshold sweep using the deployed gate's top-1
similarity. Reader evaluation separately reports abstention accuracy and
false-answer rate. Do **not** choose or tune an operating threshold on the v0
test cases; a future calibration split is required for that.

## Intended metrics

- A: exact two-axis accuracy, per-axis F1, and N/P/E/B confusion matrix.
- B: any-gold Hit@K, best-gold MRR, gold Recall@K, and answer accuracy.
- C: target Hit@K, best-target MRR, target Recall@K,
  target-before-competing, and answer accuracy split by temporal subtype.
- D retrieval: query-level AUROC and threshold sweep.
- D reader: abstention accuracy and false-answer rate, split by subtype.

Candidate-level gold/non-gold score distributions may be reported as
diagnostics, but they are not interchangeable with the query-level top-1
scores used by a deployed abstention gate.

The dataset adapter does not run Gemma, embeddings, retrieval, or iPhone code.
Those systems consume the generated cases in later evaluation runners.

## Dense retrieval baseline

`retrieval_runner.py` evaluates axes B-D only. Axis A remains a separate
memory-admission evaluation. The runner follows the current Swift
`DenseMemoryRetriever` behavior:

1. B-D user turns are injected directly without admission filtering.
2. Queries and documents use the exact iOS EmbeddingGemma prefixes.
3. Candidates are scored with cosine similarity.
4. Results are ordered by score descending, timestamp descending, then
   deterministic observation ID ascending. The benchmark uses `turn_id` as
   the injected observation ID.
5. NFKC/whitespace-normalized duplicate text is removed after sorting.
6. The requested Top-K values are scored.

The workflow is deliberately split because the frozen B-D set contains
47,691 user-turn occurrences and 42,681 unique query/document embeddings.
Embedding extraction can therefore be stopped and resumed without rerunning
completed records.

First export the canonical embedding inputs:

```bash
python3 retrieval_runner.py prepare-embeddings
```

Then use the same Python environment as `ai/memory-classifier` to extract
EmbeddingGemma vectors:

```bash
cd ../memory-classifier

uv run python ../edgemembench/retrieval_runner.py extract-embeddings \
  --model /absolute/path/to/embeddinggemma.tflite \
  --tokenizer /absolute/path/to/sentencepiece.model
```

The extractor uses:

- query: `task: search result | query: `
- document: `title: none | text: `
- sequence length: 256
- dimension: 768
- LiteRT CPU backend

It writes a resumable SQLite database under the ignored
`.artifacts/v0/retrieval/` directory. Missing dependencies, model files,
tokenizers, or embeddings fail explicitly; there is no mock/fallback
embedding path.

Finally run and score the retrieval baseline:

```bash
cd ../edgemembench
python3 retrieval_runner.py run --cutoffs 1 3 5 10 20
```

The ignored output directory contains:

- `retrieval_results.jsonl`: per-case ranks, scores, and Top-K provenance;
- `retrieval_summary.json`: B/C/D metrics, query-level AUROC, the complete
  threshold sweep, and candidate-level score distributions.

This runner does not invoke the Gemma reader. Reader-oracle and end-to-end
generation evaluation remain separate future stages.
