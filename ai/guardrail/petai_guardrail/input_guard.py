from __future__ import annotations

import gc
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from .common import GuardrailError
from .config import InputGuardConfig
from .litert_target import Generation


@dataclass(frozen=True)
class GuardDecision:
    blocked: bool
    label: str
    score: float
    latency_ms: float


class InputGuard(Protocol):
    def classify(self, prompt: str) -> GuardDecision: ...


class KoreanBertInputGuard:
    def __init__(self, config: InputGuardConfig, model_path: Path):
        import torch
        from transformers import AutoModelForSequenceClassification, AutoTokenizer

        if not config.enabled:
            raise GuardrailError("The Korean input guard is disabled in config.")
        if config.device == "auto":
            device = "mps" if torch.backends.mps.is_available() else "cpu"
        else:
            device = config.device
        self.config = config
        self._torch = torch
        self.device = device
        self.tokenizer = AutoTokenizer.from_pretrained(
            model_path, local_files_only=True
        )
        self.model = AutoModelForSequenceClassification.from_pretrained(
            model_path, local_files_only=True
        ).to(device)
        self.model.eval()
        labels = {str(label) for label in self.model.config.id2label.values()}
        if config.safe_label not in labels:
            raise GuardrailError(
                f"Input guard has no {config.safe_label!r} label: {sorted(labels)}"
            )

    def classify(self, prompt: str) -> GuardDecision:
        return self.classify_many([prompt], batch_size=1)[0]

    def classify_many(
        self, prompts: list[str], batch_size: int = 64
    ) -> list[GuardDecision]:
        decisions: list[GuardDecision] = []
        for start in range(0, len(prompts), batch_size):
            batch = prompts[start : start + batch_size]
            started = time.perf_counter()
            inputs = self.tokenizer(
                batch,
                return_tensors="pt",
                padding=True,
                truncation=True,
                max_length=self.config.max_length,
            ).to(self.device)
            with self._torch.inference_mode():
                logits = self.model(**inputs).logits
                probabilities = self._torch.softmax(logits, dim=-1)
                predicted = probabilities.argmax(dim=-1)
            latency_ms = (time.perf_counter() - started) * 1000 / len(batch)
            for row, predicted_id in zip(probabilities, predicted, strict=True):
                index = int(predicted_id.item())
                label = str(self.model.config.id2label[index])
                decisions.append(
                    GuardDecision(
                        blocked=label != self.config.safe_label,
                        label=label,
                        score=float(row[index].item()),
                        latency_ms=latency_ms,
                    )
                )
        return decisions

    def close(self) -> None:
        del self.model
        gc.collect()
        if self.device == "mps":
            self._torch.mps.empty_cache()


class GuardedTarget:
    def __init__(self, target: object, guard: InputGuard, blocked_response: str):
        self.target = target
        self.guard = guard
        self.blocked_response = blocked_response

    def generate(self, prompt: str, seed: int) -> Generation:
        decision = self.guard.classify(prompt)
        if decision.blocked:
            return Generation(
                text=f"save(P=0,E=0)\n{self.blocked_response}",
                latency_ms=decision.latency_ms,
                error=None,
                guard_decision="block",
                guard_label=decision.label,
                guard_score=decision.score,
                guard_latency_ms=decision.latency_ms,
                generation_skipped=True,
            )
        generation = self.target.generate(prompt, seed)
        return Generation(
            text=generation.text,
            latency_ms=decision.latency_ms + generation.latency_ms,
            error=generation.error,
            guard_decision="allow",
            guard_label=decision.label,
            guard_score=decision.score,
            guard_latency_ms=decision.latency_ms,
            generation_skipped=False,
        )
