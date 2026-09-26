from pathlib import Path
from types import SimpleNamespace

from petai_guardrail.common import read_jsonl, write_jsonl
from petai_guardrail.garak_runner import (
    _last_user_prompt,
    _prompt_leak_score,
    compare_garak_from_reference,
    summarize_garak_attempts,
)
from petai_guardrail.input_guard import GuardDecision


def test_last_user_prompt_uses_most_recent_user_message() -> None:
    assert (
        _last_user_prompt(
            {
                "messages": [
                    {"role": "system", "content": "system"},
                    {"role": "user", "content": "first"},
                    {"role": "assistant", "content": "answer"},
                    {"role": "user", "content": "latest"},
                ]
            }
        )
        == "latest"
    )


def test_prompt_leak_detector_flags_verbatim_excerpt() -> None:
    prompt = "This is a sufficiently long private system instruction."
    assert _prompt_leak_score(prompt, "sufficiently long private system") >= 0.5
    assert _prompt_leak_score(prompt, "unrelated answer") < 0.5


def test_garak_summary_aggregates_once_per_output() -> None:
    attempts = [
        {
            "outputs": [{"text": "ordinary answer"}],
            "detector_results": {"first": [0.1], "second": [0.9]},
        }
    ]
    summary = summarize_garak_attempts(
        attempts, "This is a sufficiently long private system instruction."
    )
    assert summary["outputs"] == 1
    assert summary["injection_attack_success_rate"]["count"] == 1
    assert summary["injection_attack_success_rate"]["total"] == 1


class FakeBatchGuard:
    def classify_many(self, prompts: list[str]) -> list[GuardDecision]:
        return [
            GuardDecision(
                blocked="block" in prompt,
                label="INJECTION" if "block" in prompt else "SAFE",
                score=0.9,
                latency_ms=1.0,
            )
            for prompt in prompts
        ]


def test_paired_garak_reuses_allowed_and_replaces_blocked(tmp_path: Path) -> None:
    reference = tmp_path / "reference.jsonl"
    write_jsonl(
        reference,
        [
            {
                "entry_type": "attempt",
                "status": 2,
                "probe_classname": "promptinject.Test",
                "prompt": {
                    "turns": [{"role": "user", "content": {"text": "allow prompt"}}]
                },
                "outputs": [{"text": "trigger"}],
                "detector_results": {"detector": [1.0]},
            },
            {
                "entry_type": "attempt",
                "status": 2,
                "probe_classname": "promptinject.Test",
                "prompt": {
                    "turns": [{"role": "user", "content": {"text": "block prompt"}}]
                },
                "outputs": [{"text": "trigger"}],
                "detector_results": {"detector": [1.0]},
            },
        ],
    )
    config = SimpleNamespace(
        garak={"probes": ["promptinject"]},
        input_guard=SimpleNamespace(blocked_response="차단"),
    )

    result = compare_garak_from_reference(
        config,
        "private system prompt",
        reference,
        tmp_path / "guarded",
        FakeBatchGuard(),
    )

    transformed = read_jsonl(tmp_path / "guarded" / "garak-paired.report.jsonl")
    assert transformed[0]["outputs"][0]["text"] == "trigger"
    assert transformed[1]["outputs"][0]["text"] == "차단"
    assert result["injection_attack_success_rate"]["count"] == 1
    assert result["input_guard"]["block_rate"]["rate"] == 0.5
