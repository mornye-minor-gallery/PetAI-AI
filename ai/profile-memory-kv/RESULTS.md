# Profile Memory KV smoke v0

## Conclusion

Gemma E2B followed the direct `{"allowed.key":"value"}` or `null` protocol
for all 24 Korean smoke cases. Explicit profile/preference extraction was
promising: key accuracy was 15/16 (93.75%). The main failure was abstention:
only 3/8 negative cases returned `null`.

This is a tiny exploratory dataset, not held-out deployment evidence.

## Contract discovery

The first prompt requested a wrapped object:

```json
{"key":"profile.school","value":"아주대학교"}
```

The model consistently emitted the simpler form instead:

```json
{"profile.school":"아주대학교"}
```

That behavior matched the intended minimal Key–Value experiment, so the final
contract adopted the direct single-entry object. The prompt's semantic rules
were not tuned between runs.

## Final smoke result

| Metric | Result |
| --- | ---: |
| Cases | 24 |
| Canonical object or `null` | 24/24 (100%) |
| Overall strict exact | 16/24 (66.67%) |
| Positive key accuracy | 15/16 (93.75%) |
| Value exact given correct key | 13/15 (86.67%) |
| Negative `null` accuracy | 3/8 (37.50%) |
| Negative false positives | 5/8 |
| Mean CPU end-to-end | 1.918s |
| Mean CPU first token | 1.678s |

## Errors

### Surface-value normalization

- Gold `3`, output `삼남매`
- Gold `사진 찍기`, output `사진 찍는 것`

Both preserve the intended meaning but fail strict string equality. Future
evaluation should define a value-normalization contract before scoring rather
than changing gold labels after observing predictions.

### Wrong key

- `미생을 제일 재미있게 봤어` was emitted as `preference.hobby` instead of
  `preference.drama`.

### False-positive profile extraction

- a question about the assistant's food preference
- another person's food preference
- a one-time latte event
- a hypothetical wish to have a sibling
- a wish to acquire a new hobby

The model recognized profile-shaped nouns but did not reliably enforce
speaker, assertion, temporality, and factuality constraints.

## Interpretation

The smoke result supports continuing the narrow experiment: explicit
profile/preference statements can already be mapped to a closed key set with a
minimal output protocol. It does not support committing every proposal to a
profile database. A fail-closed admission/abstention gate is the next issue to
study before roles, temporal versions, or a reducer.

Do not tune and report final accuracy on these same 24 cases. The next prompt
candidate should be selected on separate development examples and evaluated
on a new small holdout containing questions, third-person statements,
hypotheticals, wishes, one-time events, and quoted speech.

## Reproducibility

- Backend: LiteRT-LM 0.13.1 CPU
- Reasoning: OFF
- Temperature: 0
- Top-p: 1.0
- KV cache: 8,192 tokens
- Model SHA-256: `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`
- Dataset SHA-256: `87fb95d0854f95ce954c8959f4c8b704cc1f5190eca1c811948a50b71d295866`
- Direct-KV prompt SHA-256: `6371610bb02eb6d2d5736c3f10d62c008371e8f0f9c53c7e0ec868030888ac55`

Generated raw outputs and native logs remain under the ignored
`ai/profile-memory-kv/.artifacts/` directory.

## Three-question gate development comparison

The v1 prompt requires the model to silently check three conditions in order
before returning a Key–Value pair:

1. the speaker is the user talking about themself;
2. the statement is an asserted current fact, not a question, hypothesis,
   wish, or plan;
3. the statement describes a persistent profile or preference, not a one-time
   action.

The same 24 smoke cases were reused for a cheap directional comparison. This is
prompt-development evidence, not a held-out result.

| Metric | Minimal v0 | Three-question v1 |
| --- | ---: | ---: |
| Canonical object or `null` | 24/24 (100%) | 24/24 (100%) |
| Overall strict exact | 16/24 (66.67%) | 19/24 (79.17%) |
| Positive key accuracy | 15/16 (93.75%) | 16/16 (100%) |
| Value exact given correct key | 13/15 (86.67%) | 14/16 (87.50%) |
| Negative `null` accuracy | 3/8 (37.50%) | 5/8 (62.50%) |
| Negative false positives | 5/8 | 3/8 |

The gate corrected three prior errors:

- `미생을 제일 재미있게 봤어` changed from `preference.hobby` to
  `preference.drama`;
- a wish to have a sibling changed to `null`;
- a plan to acquire a hobby changed to `null`.

Three admission errors remain: a question about the assistant, another
person's food preference, and a one-time latte event were still extracted as
the user's persistent preference. Two positive cases remain strict
surface-value mismatches (`삼남매` versus `3`, and `사진 찍는 것` versus
`사진 찍기`).

The v1 CPU latency in this run is not comparable to v0 because machine load
changed during execution. The quality comparison used the same deployment
artifact and decoding settings, but this run is not latency evidence.

- Backend: LiteRT-LM 0.13.1 CPU
- Reasoning: OFF
- Temperature: 0
- Top-p: 1.0
- KV cache: 8,192 tokens
- Model SHA-256: `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`
- Gate-v1 prompt SHA-256: `5892ef8dad76fcccd94bd4d6ac67f6adefb10000b091687bf923ae0d78dae564`
