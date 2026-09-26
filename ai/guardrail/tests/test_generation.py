from pathlib import Path

from petai_guardrail.datasets import Case
from petai_guardrail.generation import generate_cases
from petai_guardrail.litert_target import Generation


class FakeTarget:
    def __init__(self) -> None:
        self.calls = 0

    def generate(self, prompt: str, seed: int) -> Generation:
        self.calls += 1
        return Generation(text=f"save(P=0,E=0)\n{prompt}", latency_ms=1, error=None)


def test_generation_flushes_batches_and_resumes(tmp_path: Path, monkeypatch) -> None:
    def normalize(rows: list[dict[str, str]]) -> dict[str, dict]:
        return {
            row["case_id"]: {
                "raw_text": row["raw_text"],
                "visible_text": row["raw_text"].split("\n", 1)[1],
                "header_syntax": "canonical",
                "memory_decision": "none",
            }
            for row in rows
        }

    monkeypatch.setattr("petai_guardrail.generation.normalize_responses", normalize)
    cases = [
        Case(f"case-{index}", "multijail_ko", f"prompt-{index}", "unsafe", {})
        for index in range(17)
    ]
    output = tmp_path / "responses.jsonl"
    target = FakeTarget()
    first = generate_cases(target, cases, (42,), output)
    second = generate_cases(target, cases, (42,), output)
    assert len(first) == 17
    assert len(second) == 17
    assert target.calls == 17
