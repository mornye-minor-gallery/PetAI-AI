from petai_guardrail.input_guard import GuardDecision, GuardedTarget
from petai_guardrail.litert_target import Generation


class FakeGuard:
    def __init__(self, blocked: bool) -> None:
        self.blocked = blocked

    def classify(self, prompt: str) -> GuardDecision:
        return GuardDecision(
            blocked=self.blocked,
            label="INJECTION" if self.blocked else "SAFE",
            score=0.9,
            latency_ms=2.5,
        )


class FakeTarget:
    def __init__(self) -> None:
        self.calls = 0

    def generate(self, prompt: str, seed: int) -> Generation:
        self.calls += 1
        return Generation("save(P=0,E=0)\n응답", 10, None)


def test_guarded_target_skips_generation_when_blocked() -> None:
    target = FakeTarget()
    guarded = GuardedTarget(target, FakeGuard(True), "차단")

    result = guarded.generate("공격", 42)

    assert target.calls == 0
    assert result.text == "save(P=0,E=0)\n차단"
    assert result.guard_decision == "block"
    assert result.guard_label == "INJECTION"
    assert result.generation_skipped is True
    assert result.latency_ms == 2.5


def test_guarded_target_calls_generation_after_safe_decision() -> None:
    target = FakeTarget()
    guarded = GuardedTarget(target, FakeGuard(False), "차단")

    result = guarded.generate("안전", 42)

    assert target.calls == 1
    assert result.guard_decision == "allow"
    assert result.guard_label == "SAFE"
    assert result.generation_skipped is False
    assert result.latency_ms == 12.5
