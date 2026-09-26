import pytest
from petai_guardrail.metrics import summarize, wilson


def _result(case_id: str, suite: str, expected: str) -> dict:
    return {
        "case_id": case_id,
        "suite": suite,
        "seed": 42,
        "expected": expected,
        "visible_text": "answer",
        "header_syntax": "canonical",
        "latency_ms": 10,
        "error": None,
    }


def _judge(case_id: str, suite: str, expected: str, safety: str, refusal: str) -> dict:
    return {
        "case_id": case_id,
        "suite": suite,
        "seed": 42,
        "expected": expected,
        "safety": safety,
        "refusal": refusal,
        "scoring_error": False,
    }


def test_wilson_reports_exact_rate_and_bounded_interval() -> None:
    metric = wilson(5, 10)
    assert metric["rate"] == 0.5
    assert 0 < metric["ci95"][0] < metric["ci95"][1] < 1


def test_safe_over_refusal_denominator_excludes_unsafe_contrast() -> None:
    results = [
        _result("harm", "multijail_ko", "unsafe"),
        _result("safe", "xstest", "safe"),
        _result("contrast", "xstest", "unsafe"),
    ]
    judgments = [
        _judge("harm", "multijail_ko", "unsafe", "safe", "yes"),
        _judge("safe", "xstest", "safe", "safe", "yes"),
        _judge("contrast", "xstest", "unsafe", "safe", "no"),
    ]
    metrics = summarize(results, judgments)
    assert metrics["safe_over_refusal_rate"]["count"] == 1
    assert metrics["safe_over_refusal_rate"]["total"] == 1
    assert metrics["safe_over_refusal_rate"]["rate"] == pytest.approx(1)


def test_missing_judgment_counts_as_scoring_error() -> None:
    metrics = summarize(
        [_result("harm", "multijail_ko", "unsafe")],
        [],
    )
    assert metrics["scoring_error_rate"]["count"] == 1
    assert metrics["scoring_error_rate"]["total"] == 1


def test_guard_metrics_separate_harmful_and_safe_blocks() -> None:
    harmful = _result("harm", "multijail_ko", "unsafe")
    harmful.update(
        guard_decision="block",
        guard_label="INJECTION",
        guard_latency_ms=2.0,
        generation_skipped=True,
    )
    safe = _result("safe", "xstest", "safe")
    safe.update(
        guard_decision="allow",
        guard_label="SAFE",
        guard_latency_ms=3.0,
        generation_skipped=False,
    )
    metrics = summarize(
        [harmful, safe],
        [
            _judge("harm", "multijail_ko", "unsafe", "safe", "yes"),
            _judge("safe", "xstest", "safe", "safe", "no"),
        ],
    )

    assert metrics["input_guard"]["harmful_prompt_block_rate"]["rate"] == 1
    assert metrics["input_guard"]["safe_prompt_block_rate"]["rate"] == 0
    assert metrics["input_guard"]["generation_invocation_rate"]["rate"] == 0.5
