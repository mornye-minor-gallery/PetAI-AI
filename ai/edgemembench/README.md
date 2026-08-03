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

## Temporal version cohort diagnostic

`cohort_similarity_runner.py` tests one narrow hypothesis before any new
reranking policy is implemented: whether two manually reviewed versions of
the same fact have higher document-to-document cosine similarity than other
retrieved memories. It also measures a deterministic combined gate that
requires both cosine similarity and shared content tokens.

The diagnostic uses the 58 scored C-axis cases that contain both target and
competing evidence. Their target/competing Cartesian product produces 59
positive version pairs. Operational negatives pair those evidence turns with
non-evidence candidates in the same Dense Top-20; context evidence is excluded
because it may belong to the same fact scenario.

Run it after the frozen embedding database has been prepared:

```bash
python3 cohort_similarity_runner.py
```

The ignored `retrieval/cohort-similarity/` output contains:

- `pair_scores.jsonl`: source text, timestamps, pair labels, and cosine scores;
- `threshold_sweep.json`: exploratory precision/recall and false-pair counts;
- `combined_gate_sweep.json`: cosine-plus-token-overlap threshold grid;
- `partner_top1_sweep.json`: one strongest eligible partner per gold anchor;
- `summary.json`: intrinsic/operational coverage, score distributions,
  AUROC, average precision, and positive-versus-hardest-negative margins.
- `annotation_rescore_summary.json`: blind silver-label pair separation;
- `annotation_threshold_sweep.json`: annotation-based cosine/overlap sweep;
- `annotation_partner_top1_sweep.json`: annotation-based partner precision,
  coverage, abstention, and error counts.
- `annotation_partner_failure_analysis.json`: anchor-level wrong selections,
  blind reasons, annotated alternatives, score gaps, and gate transitions.
- `annotation_abc_policy_sweep.json`: query-only, pair-only, and query-band
  then pair-cosine policy comparison with anchor-level transitions.

Content tokens use NFKC normalization and case folding, then remove numeric
values, dates/times, generic English stopwords, and temporal markers. The
overlap score is the exact set-intersection count. This rule is intentionally
limited to the English v0 benchmark; it is not yet a Korean morphology
contract. Rows whose cosine threshold is `-1.0` are the overlap-only reference.

The partner Top-1 diagnostic treats each target/competing evidence turn as an
anchor and selects at most one partner after the gates. Selection uses cosine
descending, overlap descending, then partner ID ascending. It reports correct,
incorrect, and abstained anchors separately. This checks whether a reliable
cohort edge can be found; it does not yet build connected clusters or require
mutual nearest partners.

## Blind cohort-pair labeling

`cohort_labeler.py` builds a deduplicated blind-review queue from the 59
reviewed target/competing seeds and the union of pairs selected by the partner
Top-1 sweep. Queue order is shuffled deterministically with seed 42. The web UI
shows only the two texts and their timestamps; case IDs, source groups,
selection configurations, cosine, overlap, and previous labels remain hidden.

Prepare and open the localhost-only labeler:

```bash
python3 cohort_labeler.py prepare
python3 cohort_labeler.py serve --open
```

Annotations use one of three labels:

- `same_cohort`: the same entity/attribute is updated, corrected, or restated;
- `different_cohort`: a different attribute, independent event, or entity;
- `ambiguous`: the pair alone does not establish a temporal replacement.

Progress is saved atomically under the ignored
`.artifacts/v0/retrieval/cohort-labeling/annotations.draft.jsonl`. Validate it
at any point with:

```bash
python3 cohort_labeler.py validate
```

Export is fail-closed until every pair has been reviewed. The exported file
contains IDs, text hashes, labels, reasons, and notes, but not the source text:

```bash
python3 cohort_labeler.py export
```

The default export target is the versioned
`data/cohort_pair_annotations.jsonl`. Do not export or commit a partial draft.

For agent-assisted review, assign every pair to two independent annotators and
keep the blind inputs free of source labels, similarity scores, case IDs, and
selection provenance. Reconcile votes with `reconcile-agent-votes`: matching
labels are accepted, disagreements are emitted as blind files for the one
annotator who has not seen that pair, and a third vote resolves the label by
majority. If all three labels differ, a fresh fourth blind vote breaks the tie.
The consensus draft preserves annotator IDs, individual votes, and whether the
result was direct agreement, adjudication, or tiebreak. Agent-produced labels
are evaluation annotations, not human ground truth.

The first frozen review contains 178 pairs. Two independent GPT-5.6-sol
decisions agreed on 161 pairs (90.45%); 16 disagreements were resolved by a
blind third vote, and one three-way tie by a fresh fourth vote. Pairwise
Cohen's kappa across the three rotating annotator pairs ranged from 0.559 to
0.882. The final distribution is 128 `same_cohort`, 48 `different_cohort`, and
2 `ambiguous`. Of the 59 original target/competing seeds, the blind result
retained 52 as `same_cohort`, rejected 6, and left 1 ambiguous. These numbers
characterize repo-local AI-assisted annotation consistency, not
human-validated generalization quality.

Rescore the frozen pair and partner artifacts without recomputing embeddings:

```bash
python3 cohort_similarity_runner.py --rescore-annotations
```

The 176 non-ambiguous silver pairs contain 128 positives and 48 negatives, so
the positive prevalence is 72.73%. Pairwise cosine alone reaches AUROC 0.594
and AP 0.808; deterministic content-token overlap reaches AUROC 0.715 and AP
0.864. For the 117 original anchors, ungated highest-cosine partner selection
has 76.07% precision at 100% coverage. Requiring overlap >= 5 yields 83.00%
decided precision at 86.32% coverage; additionally requiring cosine >= 0.70
yields 86.36% precision at 56.41% coverage.

These semantic-cohort numbers must not be compared as an algorithmic gain
against the old exact-gold-partner score. The old metric counted any partner
outside the manually nominated target/competing pair as wrong, even when the
blind review judged it to be another valid version of the same memory slot.
The annotation queue is also selection-biased toward reviewed seeds and pairs
chosen somewhere in the exploratory sweep. The results correct the evaluation
contract, but still do not select a deployment threshold.

The ungated Top-1 failure analysis contains 28 anchors: 20 select a different
attribute of the same broad topic, 6 select a separate event, and 2 select a
different entity. An annotated same-cohort alternative exists for 23 of these
anchors. The wrong pair exceeds the best annotated alternative by median
cosine 0.057, but the valid alternative has greater query-to-partner content
overlap in 18/23 cases. The original query-to-candidate Dense score also favors
the valid alternative in 16/23 cases, by a median margin of 0.060. Applying
overlap >= 5 changes 10 failures to a valid cohort, abstains on 6, and leaves
12 wrong. This supports retaining the existing query relevance score before
adding a new attribute/relation signal. It does not justify selecting a score
combination or adding a product rule from the v0 test set alone.

## A/B/C query-score policy diagnostic

The A/B/C diagnostic adds 64 selected pairs that were not present in the base
178-pair queue. They are frozen separately in
`data/cohort_abc_candidate_annotations.jsonl`: 54 received direct independent
agreement and 10 blind third-vote adjudication, producing 44 `same_cohort` and
20 `different_cohort` labels.

The policies all make one selection for each of 117 anchors:

- A (`delta=inf`): ignore query-score differences and maximize pair cosine;
- B (`delta=0`): keep only the maximum query-score partner;
- C: retain partners within `delta` of the maximum query score, then maximize
  pair cosine inside that band.

Repo-local v0 results are A 76.07%, B 82.76%, and exploratory C at
`delta=0.05` 84.62% decided precision. Relative to A, that C row repairs 18
wrong selections and regresses 8 correct selections, for a net gain of 10
same-cohort anchors. This establishes that the two existing scores carry
complementary signal. It does not establish `delta=0.05` as a deployable value:
the delta sweep and evaluation used the same v0 test cases, so a separate
calibration set is required.

This is a cohort-identification diagnostic only. It does not change Dense
order, run temporal reranking, or select a deployment threshold. EdgeMemBench
v0 is a test set, so an operating threshold requires a separate calibration
split.

## Korean cohort-delta calibration v1

`data/cohort_delta_calibration.jsonl` is independent of the LongMemEval-based
v0 cases. It contains 50 Korean PetAI-like selection situations and 100
candidate pairs. Every situation has exactly one same-attribute update and
one hard negative representing a different attribute, separate event, or
different entity. Fact families are unique across the two splits:

- calibration: 35 situations / 70 pairs;
- holdout: 15 situations / 30 pairs.

The calibration runner uses the exact current iOS EmbeddingGemma artifact,
prefixes, sequence length, and LiteRT CPU path. It selects `delta` only from
the 35 calibration situations. Accuracy ties choose the smallest finite
delta. The 15-case holdout is opened only after that value is frozen.

```bash
python3 cohort_calibration_runner.py validate
python3 cohort_calibration_runner.py prepare-embeddings

cd ../memory-classifier
uv run python ../edgemembench/cohort_calibration_runner.py extract-embeddings \
  --model ../.artifacts/runtime-models/embedding/embeddinggemma-300m/embeddinggemma-300M_seq256_mixed-precision.tflite \
  --tokenizer ../.artifacts/runtime-models/embedding/embeddinggemma-300m/sentencepiece.model

cd ../edgemembench
python3 cohort_calibration_runner.py evaluate
```

The selected value is `delta=0.05`. On calibration, B (`delta=0`) scores
29/35 (82.86%), frozen C scores 32/35 (91.43%), and A (`delta=inf`) scores
23/35 (65.71%). On the untouched 15-case holdout, B scores 12/15 (80.00%),
frozen C scores 13/15 (86.67%, Wilson 95% CI 62.12%-96.26%), and A scores
11/15 (73.33%).

After freezing `delta=0.05`, the existing v0 diagnostic was rerun once as a
retrospective regression check: B remains 96/117 same-cohort selections
(82.05% strict), frozen C 99/117 (84.62%), and A 89/117 (76.07%). v0 is not
a clean holdout because it was already inspected during algorithm design.

This result supports `0.05` as the current repo-local candidate, not as a
general deployment constant. The Korean set is manually authored synthetic
data, the holdout is small, and neither split contains production
conversations or independent human labels. Swift integration should retain
the frozen value and contract, then be verified separately on device.

## Cohort-local temporal resolution diagnostic

`cohort_temporal_resolver.py` tests what happens after cohort calibration when
the policy is applied to the actual frozen Dense Top-20. It reads the existing
EmbeddingGemma SQLite database and performs only CPU cosine and ordering work;
it does not run EmbeddingGemma or a reader model.

The 69 scored C cases derive a query view from the manually reviewed subtype
contract in `data/temporal_view_contract.json`:

- `current_state` -> `current`;
- `historical_state` -> `historical_previous`;
- `multi_state` -> `transition`;
- `single_state` -> `neutral`;
- the explicit trip before `7/22` -> strict `as_of(7/22)`.

```bash
python3 cohort_temporal_resolver.py
```

The runner compares Dense (`R0`), global timestamp reranking (`R1`), predicted
two-member cohort with always-latest (`R2`), predicted cohort with query-view
routing (`R3`), and three gold cohort/view oracles (`O1`-`O3`). Candidate sets
never change. EdgeMemBench v0 remains a retrospective regression set, so the
runner does not tune `delta=0.05`, parser rules, or another operating value.

| Policy | Hit@1 | MRR | improved / regressed vs Dense |
| --- | ---: | ---: | ---: |
| R0 Dense | 33.33% | 0.5748 | 0 / 0 |
| R1 global timestamp | 40.58% | 0.6408 | 20 / 2 |
| R2 predicted cohort + latest | 39.13% | 0.6038 | 7 / 3 |
| R3 predicted cohort + query view | 40.58% | 0.6135 | 8 / 3 |
| O1 gold cohort + gold view | 97.10% | 0.9855 | 44 / 0 |
| O2 predicted cohort + gold view | 40.58% | 0.6135 | 8 / 3 |
| O3 gold cohort + predicted view | 94.20% | 0.9620 | 42 / 0 |

The effective query-view parser matches 58/69 (84.06%). The deployment-shaped
policy selects a partner in 35/69 cases; 10/35 exactly match the benchmark's
manually nominated target/competing versions. That exact-alignment number is
not semantic cohort precision. Existing blind annotations cover 26 of the 35
selected pairs and label 20 `same_cohort` versus 6 `different_cohort`, or
76.92% decided precision with nine unannotated pairs. Dense Top-1 is itself a
gold version in 42/69 cases. The gap is therefore narrower: the policy often
finds a semantically related cohort member, but does not reliably identify an
answer-bearing state version that is safe to promote by time.

The strict `as_of` oracle also fails because C stores session `occurredAt`,
while `7/10` and `7/22` occur only inside the text. This is direct evidence for
the documented valid-time versus recorded-time representation gap. Detailed
rows, parser failures, cohort buckets, and rank changes are written under the
Git-ignored `retrieval/cohort-temporal-resolution-v1/` directory.

## Mutual-nearest and margin gate diagnostic

`cohort_gate_diagnostic.py` adds fail-closed gates without changing which
partner the baseline selects. `mutual` requires the anchor and partner to be
each other's nearest member inside the query-score band. `margin` requires the
chosen pair cosine to exceed the anchor's second-best pair cosine by a swept
amount. The v0 sweep is diagnostic and selects no threshold.

```bash
python3 cohort_gate_diagnostic.py
```

| Gate | Coverage | Annotated decided precision | Hit@1 | Dense Hit@1 regressions |
| --- | ---: | ---: | ---: | ---: |
| no gate | 50.72% | 76.92% | 40.58% | 3 |
| mutual only | 44.93% | 79.17% | 42.03% | 1 |
| mutual + margin 0.03 | 7.25% | 75.00% | 33.33% | 0 |
| margin 0.10 | 2.90% | 100.00% | 33.33% | 0 |

Mutual-nearest removes four selections, including two of the three downstream
regressions, but also removes one useful historical correction. The margin
gate rapidly collapses coverage and does not monotonically improve semantic
precision. A large pair-score gap means only that one candidate is much more
similar than the others; it does not prove that the pair expresses the same
attribute.

One remaining mutual regression is especially informative. The chosen 5K
partner is blind-labeled `same_cohort/restatement`, but it does not state the
personal-best value requested by the query. Promoting the newer restatement
therefore moves an already-correct Dense Top-1 to rank 2. Future annotations
and gates must distinguish semantic relatedness from an explicit
state-bearing value update. The ignored `retrieval/cohort-gate-diagnostic-v1/`
directory contains the full sweep and case rows.
