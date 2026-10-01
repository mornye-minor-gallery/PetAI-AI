# Chat input filter generator

This folder contains the generator and synthetic tests, not the reviewed filter list. The
candidate files, model decisions, and generated Unity resource stay under ignored local
paths. Publishing this generator does **not** reproduce the exact app policy without
those private review results.

The pinned candidate sources are [Korcen](https://github.com/Tanat05/korcen/tree/eecd9763dbdccce3dc96ddb578ef0b6396058fa9)
([MIT license](https://github.com/Tanat05/korcen/blob/eecd9763dbdccce3dc96ddb578ef0b6396058fa9/LICENSE))
and [LDNOOBW English](https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words/blob/5faf2ba42d7b1c0977169ec3611df25a3c08eb13/en)
([CC BY 4.0 license](https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words/blob/5faf2ba42d7b1c0977169ec3611df25a3c08eb13/LICENSE)).
The source lists are candidates only; they are not copied wholesale into the app.
Shipping a policy derived from them requires the corresponding license notices in the
app. This README is not a substitute for user-facing attribution.

From the repository root:

```sh
python3 -m ai.guardrails.input_filter_generator.generate fetch-candidates \
  --output ai/guardrails/input_filter_generator/.artifacts/candidates.json
python3 -m ai.guardrails.input_filter_generator.review \
  --candidates ai/guardrails/input_filter_generator/.artifacts/candidates.json \
  --first-review ai/guardrails/input_filter_generator/.artifacts/first-review.json \
  --second-review ai/guardrails/input_filter_generator/.artifacts/second-review.json
python3 -m ai.guardrails.input_filter_generator.generate build-policy \
  --candidates ai/guardrails/input_filter_generator/.artifacts/candidates.json \
  --first-review ai/guardrails/input_filter_generator/.artifacts/first-review.json \
  --second-review ai/guardrails/input_filter_generator/.artifacts/second-review.json \
  --output ai/guardrails/input_filter_generator/.artifacts/ChatInputFilterPolicy.json
```

The reviewer runs two independent `gpt-6-luna` `xhigh` passes, each in an empty temporary
working directory with no requested tool use. It checks returned IDs and rejects tool
events. Both passes must say `block`; disagreement excludes a term. Each batch updates
an ignored checkpoint, so interrupted runs can resume. The runtime policy includes only
literal Korean contains-rules and English whole-word rules; it cannot understand
context, and spelling evasions are not fully covered.

Run synthetic generator tests with:

```sh
python3 -m unittest discover -s ai/guardrails/input_filter_generator/tests -v
```

Do not add `.artifacts/`, the Unity policy resource, reviewer logs, or real candidate
terms to Git or public CI artifacts.
