# Needle 2 Argument Canary Results

status:: exploratory canary, not integrated
date:: 2026-08-13

## Decision

The public Needle 2 model is not a zero-shot replacement for PetAI's Gemma 4
E2B argument proposer. Even after the router-selected tool, PetAI rules, device
clock, and field schema were supplied, Needle produced no fully acceptable
proposal in the 14-case Korean `ready` canary.

Needle remains a fine-tuning candidate because its median Mac CPU completion
latency was much lower. Product integration should not start before a Korean
PetAI fine-tune clears a larger unseen argument holdout.

## Locked comparison

All arms used:

- The same 21 cases and labels locked before the five-arm ablation run.
- Exactly one router-selected Tool per case.
- The same base field names, types, required fields, and descriptions copied
  from `LiteRTLMNativeToolProposalGenerator.swift`.
- The same fixed clock: `2026-08-13T21:00:00+09:00`.
- Production `NativeToolProposalParser` and `NativeToolProposalValidator`
  source compiled directly for final validation.

The arms were:

| Arm | Contract |
| --- | --- |
| `gemma_current` | Current per-tool prompt plus current one-tool schema |
| `gemma_schema_only` | Base one-tool schema and device facts only |
| `gemma_enriched` | Current prompt rules folded into that one-tool schema |
| `needle_schema_only` | Base one-tool schema and device facts only |
| `needle_enriched` | Current prompt rules folded into that one-tool schema |

`gemma_current` versus `needle_enriched` is the practical substitution
comparison. `gemma_schema_only` versus `needle_schema_only` is the common
schema ablation. `gemma_enriched` checks whether folding instructions into the
schema is itself harmful or beneficial independently of Needle.

Several ready prompts were reused from the exploratory smoke that exposed the
original unfair seven-Tool comparison. This is therefore a reproducible
diagnostic canary, not a blind or untouched holdout.

## Ready results

`proposal_pass` requires the selected Tool, critical date/time/duration fields,
user-evidenced text fields, and the production Swift validator to all pass.

| Arm | Proposal pass | Swift validation | Strict full-object exact | Median completion |
| --- | ---: | ---: | ---: | ---: |
| `gemma_current` | 13/14 (92.86%) | 14/14 | 7/14 | 5,921 ms |
| `gemma_schema_only` | 11/14 (78.57%) | 11/14 | 4/14 | 6,275 ms |
| `gemma_enriched` | **14/14 (100%)** | **14/14** | 6/14 | 6,437 ms |
| `needle_schema_only` | 0/14 (0%) | 2/14 | 0/14 | **547 ms** |
| `needle_enriched` | 0/14 (0%) | 3/14 | 0/14 | 714 ms |

Strict full-object exact is intentionally secondary because `약 복용 알림`
and `약 먹기` can both preserve the user's evidence. The zero Needle proposal
score does not come from this text variation: its critical date/time/duration
fields and Swift validation also failed.

## Failure audit

The one `gemma_current` proposal failure was:

- `오늘 걸음 수 알려줘`: emitted `aggregation=daily` instead of the
  canonical `total`. The proposal remained schema-valid and passed Swift
  validation.

`gemma_enriched` emitted `total` for the same case and passed all 14. This is a
small, already-observed canary result, not sufficient evidence to change the
production prompt contract without a new unseen holdout.

Representative `needle_enriched` failures:

- `10초 타이머 맞춰줘`: duration `10` was correct, but label became `맞춰줘`.
- `라면 3분 타이머 시작해줘`: emitted `durationSeconds=3`, not `180`.
- `8월 15일 오후 2시 30분에 약속 알람 맞춰줘`: emitted an empty date,
  hour `8`, and minute `15`.
- Calendar event and notification cases frequently truncated or produced
  seconds-bearing timestamps rejected by PetAI's `YYYY-MM-DDTHH:mm` parser.
- One step-count case emitted an invalid aggregation string.
- Needle's confidence did not separate correct from unsafe outputs. An
  invalid argument object could have higher confidence than a partly correct
  timer call.

Some Needle failures surfaced a runtime `UnicodeDecodeError` after repeated
Korean text was truncated. These are counted as runtime failures, not safe
abstentions.

## Secondary misroute defense

The seven `defense` cases deliberately simulate a false-positive upstream
route. They are not part of the argument-proposal promotion score.

| Arm | Error-free abstention |
| --- | ---: |
| `gemma_current` | 4/7 |
| `gemma_schema_only` | 7/7 |
| `gemma_enriched` | 7/7 |
| `needle_schema_only` | 1/7 |
| `needle_enriched` | 1/7 |

Needle often produced no call here, but most such cases were truncation or
UTF-8 runtime errors. They were therefore not credited as safe abstentions.

## Provenance and limits

- Gemma: deployment `gemma-4-E2B-it.litertlm`, SHA-256
  `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`.
- Gemma runtime: LiteRT-LM `0.14.0`, CPU, MTP disabled, deterministic sampling.
- Needle package: `cactus-needle==2.0.2`; bundled engine `2.0.1`, SHA-256
  `eba68645391d3e9c899ecfde25f84649294dfa869d93aaa6a273cfc9d54f209f`.
- Dataset SHA-256:
  `795ab85759bc149e5166bd078461f88d39e93b0bb9a4835834c0cd24f284597f`.
- Latency excludes model initialization and is an exploratory Mac CPU number.
- iPhone integration, latency, RAM, thermal behavior, battery use, and binary
  signing are `UNVERIFIED`.
- Fourteen positive cases are enough to reject this zero-shot candidate, not
  enough to estimate production accuracy.

## Next gate

Only continue if Needle is fine-tuned on Korean PetAI argument examples. The
next evaluation must use a newly authored, unseen holdout and keep Tool routing
fixed outside the model. A tuned candidate should at minimum match Gemma on:

1. critical argument exactness;
2. production Swift validation pass;
3. runtime-error rate;
4. missing-parameter abstention;
5. iPhone completion latency and peak memory.
