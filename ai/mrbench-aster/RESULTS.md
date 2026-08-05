# MRBench-Aster Results

## Final research decision

Status: `frozen_best_found_mvp_candidate_not_gold` at benchmark
`0.32.0-draft`.

The selected system is hierarchical rather than one monolithic persona prompt:

1. `boundary-v2.md` classifies `BOUNDARY` versus `IN_SCOPE`;
2. boundary requests receive `boundary-card-v2.md` and respond immediately;
3. in-scope requests use `scene-v8.md` to select a granular scene card;
4. the selected card from `cards-v14-hybrid.json` is appended to
   `v14-core-boundary.md` for the response pass.

The exact component paths and hashes are frozen in
`prompts/final/selection-v0.32.json`. The canonical persona was not edited;
its SHA-256 remains
`252a02b14c20164661aa2b7bf73d36f7dd9031ca766dce8de513b273d1e9ac42`.

## Final target and evidence

- model: Gemma 4 E2B IT deployment `.litertlm`;
- model SHA-256: `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`;
- runtime: LiteRT-LM 0.13.1, Mac GPU, reasoning off;
- generation: temperature 0.7, maximum 256 response tokens;
- fixed set: 30 MS plus 30 MB cases;
- extra diagnostic holdout: 18 unseen router prompts, excluded from official 60;
- two full fixed-set runs produced identical 60/60 routes and response texts
  after excluding timing and usage metadata;
- mean latency: 776.0 ms overall, 924.8 ms for three-pass MS, 627.3 ms
  for two-pass MB;
- deterministic screen: zero honorific matches and zero output-format leaks;
- fixed MS scene routing: 29/30;
- fixed MB boundary routing: 30/30;
- manual forbidden-claim audit on MB: 28/30;
- hierarchical holdout routing: 16/18.

This meets the practical latency and reproducibility target but does not meet
the research-gold target of zero hard failures and robust holdout routing.

## What improved

The original prose/MRPrompt and compact single-pass variants often ignored
scene facets. On the five ambiguous-direction cases, the initial full and
compact prompts used the required compass in 0/5 cases. A gold-facet oracle
showed that the response model could enact a card when the correct card was
made active, identifying scene selection as the first bottleneck.

A six-label two-pass router reached 30/30 on the development MS set but broad
cards either under-activated or copied examples into unrelated sub-scenes.
Splitting the six facets into narrow labels made first contact, culture,
ambiguity, return, support, and playful behavior more reliable. The selected
`scene-v8` plus `cards-v14` combination reached 30/30 routes before the
boundary layer and improved culture questioning to 5/5 while reducing the
mean response length.

The standalone compact prompt failed many MB items by inventing home-world
politics, technology, memories, and external capabilities. Adding only core
boundary prose was insufficient. A separate binary boundary pass raised MB
boundary routing to 30/30 and removed most explicit inaccessible claims.

## Judge instability and replacement

Single independent Luna 1–10 scores are not valid for candidate ranking in
this experiment. Re-scoring byte-identical responses changed ME-MAC by a mean
absolute 0.67 points with a maximum of 2, and ME-HLE by a mean absolute 0.92
points with a maximum of 3.

Candidate selection therefore uses blinded pairwise comparison:

- both replies appear in the same judge request;
- A/B position is deterministically randomized and reversed across repeats;
- only changed replies are compared;
- each case is judged three times and reduced by case-level majority vote.

For the last fully repeated comparison, granular v11 beat broad-card v3:

| Metric | v11 wins | v3 wins | Ties |
| --- | ---: | ---: | ---: |
| ME-MAC | 10 | 3 | 2 |
| ME-HLE | 9 | 5 | 1 |

The difference consistently favored v11 but was not research-gold statistical
evidence; for example the ME-MAC two-sided sign-test value is approximately
`p=0.092`. Absolute raw judge scores remain diagnostic only and must not be
used to rank versions.

## Overfitting findings

Three distinct forms of overfitting occurred.

1. **Development-set router overfitting.** `scene-v4` reached 30/30 after being
   tuned on the same 30 MS cases, but an unseen 18-case router holdout dropped
   to 17/18. Later hierarchical boundary routing scored 30/30 on fixed MB but
   misclassified two playful holdout prompts, giving 16/18 overall.
2. **Example-copy overfitting.** Broad cards with exact answer examples copied
   the smile response into unrelated return questions. Stricter templates
   later leaked literal `X` or produced malformed names. Narrow cards reduced
   cross-scene copying but also made some replies repetitive.
3. **Judge overfitting/noise.** Optimizing against one absolute Luna score
   would select versions based on judge variance rather than Gemma behavior.
   Blinded repeated A/B reduced, but did not eliminate, this risk.

The two final MB failures demonstrate residual model-capacity limits rather
than hidden success: `aster-mb-046` still claims the home world is more
scientifically advanced, and `aster-mb-050` still claims it has no government.

## Reproduction command

With the LiteRT-LM server on `127.0.0.1:9379`, run:

```bash
python3 ai/mrbench-aster/run_routed_generation.py \
  --base-url http://127.0.0.1:9379/v1 \
  --model gemma4-e2b,gpu \
  --model-artifact ai/.artifacts/runtime-models/chat/gemma-e2b-it/gemma-4-E2B-it.litertlm \
  --runtime litert-lm \
  --runtime-version 0.13.1 \
  --backend gpu \
  --persona-prompt ai/mrbench-aster/prompts/candidates/v14-core-boundary.md \
  --boundary-router-prompt ai/mrbench-aster/prompts/router/boundary-v2.md \
  --boundary-card ai/mrbench-aster/prompts/router/boundary-card-v2.md \
  --router-prompt ai/mrbench-aster/prompts/router/scene-v8.md \
  --facet-cards ai/mrbench-aster/prompts/router/cards-v14-hybrid.json \
  --temperature 0.7 \
  --ability all \
  --output-dir ai/mrbench-aster/.artifacts/final-reproduction
```

Physical iPhone latency, memory, thermal, battery, and sustained-load behavior
remain `UNVERIFIED` and are outside this Mac prompt-selection result.
