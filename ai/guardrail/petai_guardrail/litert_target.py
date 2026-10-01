from __future__ import annotations

import time
from dataclasses import dataclass

import httpx

from .config import TargetConfig


@dataclass(frozen=True)
class Generation:
    text: str
    latency_ms: float
    error: str | None
    guard_decision: str | None = None
    guard_label: str | None = None
    guard_score: float | None = None
    guard_latency_ms: float | None = None
    generation_skipped: bool = False


class LiteRTTarget:
    def __init__(self, config: TargetConfig, system_prompt: str):
        self.config = config
        self.system_prompt = system_prompt
        self.client = httpx.Client(timeout=config.timeout_seconds)

    def close(self) -> None:
        self.client.close()

    def generate(self, prompt: str, seed: int) -> Generation:
        started = time.perf_counter()
        try:
            response = self.client.post(
                f"{self.config.base_url}/chat/completions",
                json={
                    "model": self.config.model_spec,
                    "messages": [
                        {"role": "system", "content": self.system_prompt},
                        {"role": "user", "content": prompt},
                    ],
                    "temperature": self.config.temperature,
                    "top_k": self.config.top_k,
                    "top_p": self.config.top_p,
                    "seed": seed,
                    "stream": False,
                },
            )
            response.raise_for_status()
            body = response.json()
            text = body["choices"][0]["message"]["content"]
            if not isinstance(text, str):
                raise TypeError("response content is not text")
            return Generation(
                text=text,
                latency_ms=(time.perf_counter() - started) * 1000,
                error=None,
            )
        except (httpx.HTTPError, KeyError, IndexError, TypeError, ValueError) as error:
            return Generation(
                text="",
                latency_ms=(time.perf_counter() - started) * 1000,
                error=f"{type(error).__name__}: {error}",
            )
