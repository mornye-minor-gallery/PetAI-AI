# Needle 2 Argument Canary

This canary answers one narrow question:

> After PetAI's router has already selected exactly one native tool, can
> Needle 2 replace Gemma 4 E2B as the argument proposal model?

It does not evaluate tool routing. Every case supplies exactly one
router-selected tool to both models.

## Arms

| Arm | Model | Tool contract |
| --- | --- | --- |
| `gemma_current` | deployment Gemma 4 E2B | current per-tool system prompt + current one-tool schema |
| `gemma_schema_only` | deployment Gemma 4 E2B | current one-tool schema + device facts only |
| `gemma_enriched` | deployment Gemma 4 E2B | prompt rules folded into the same one-tool schema |
| `needle_schema_only` | Needle 2 | current one-tool schema + device facts only |
| `needle_enriched` | Needle 2 | prompt rules folded into the same one-tool schema |

`gemma_current` versus `needle_enriched` is the product-candidate comparison.
The other arms identify whether a difference comes from the model or from the
extra PetAI instructions.

## Dataset

`datasets/canary.v1.jsonl` is a deliberately small pre-integration canary:

- 14 router-positive cases: two per native tool.
- 7 secondary misroute-defense cases: one per native tool.
- Fixed device clock: `2026-08-13T21:00:00+09:00`.

The contract and labels were locked before the five-arm ablation run. Several
ready prompts were reused from the exploratory smoke that motivated this fair
rerun, so this is a diagnostic canary, not a blind holdout.

The primary result is the `ready` slice. The `defense` slice is diagnostic and
must not be presented as the argument model's routing score.

## Metrics

- `call_exact`: one error-free call for `ready`, an error-free abstention for
  `defense`. Runtime truncation is not counted as a safe abstention.
- `tool_exact`: emitted tool name equals the router-selected tool.
- `strict_argument_exact`: the full canonical argument object matches.
- `critical_argument_exact`: dates, times, durations, ranges, and aggregation
  match exactly.
- `text_evidence_pass`: generated labels, titles, bodies, and locations contain
  the required user evidence.
- `proposal_pass`: tool, critical arguments, text evidence, and the production
  Swift validator all pass. For `defense`, it requires an error-free abstention.
- `swift_parse_pass` and `swift_validation_pass`: output is accepted by the
  production `NativeToolProposalParser` and `NativeToolProposalValidator`.

The Swift validation step compiles the production source files directly; the
canary does not maintain a second validator implementation.

## Run

The deployment Gemma artifact must already exist at the registry path under
`ai/.artifacts/runtime-models/`.

```bash
ai/needle2-argument-canary/scripts/run-canary.sh
```

Generated predictions, logs, manifests, and summaries are written below
`ai/needle2-argument-canary/.artifacts/` and are not committed.

This Mac run is a quality and exploratory latency canary. iPhone latency,
memory, thermal behavior, binary integration, and signing remain `UNVERIFIED`.
