"""Isolated LiteRT-LM worker for parallel Gemma routing.

This module intentionally uses Python 3.10-compatible syntax because the
official LiteRT-LM uv tool can use an older interpreter than FacetRouteBench.
The parent harness validates every contract and pre-renders router inputs; this
worker only performs inference and writes resumable predictions.
"""

import argparse
import json
import re
import time
from pathlib import Path


def parse_unique_route(raw_text, route_ids):
    upper = raw_text.upper()
    matches = [
        route
        for route in route_ids
        if re.search(
            r"(?<![A-Z0-9_])" + re.escape(route) + r"(?![A-Z0-9_])",
            upper,
        )
    ]
    return matches[0] if len(matches) == 1 else None


def read_jsonl(path):
    with Path(path).open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def append_jsonl(handle, value):
    handle.write(
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    )
    handle.flush()


class Router:
    def __init__(self, model_path, backend, max_num_tokens):
        import litert_lm

        backend_value = {
            "cpu": litert_lm.Backend.CPU,
            "gpu": litert_lm.Backend.GPU,
        }[backend]
        started = time.perf_counter()
        self._context = litert_lm.Engine(
            str(model_path),
            backend=backend_value(),
            max_num_tokens=max_num_tokens,
        )
        self._engine = self._context.__enter__()
        self._sampler = litert_lm.SamplerConfig(temperature=0.0, top_p=1.0)
        self.load_elapsed_ms = round((time.perf_counter() - started) * 1000, 3)

    def generate(self, system_prompt, user_message):
        chunks = []
        first_output = None
        started = time.perf_counter()
        with self._engine.create_conversation(
            messages=[{"role": "system", "content": system_prompt}],
            extra_context={"enable_thinking": False},
            filter_channel_content_from_kv_cache=True,
            sampler_config=self._sampler,
        ) as conversation:
            for chunk in conversation.send_message_async(user_message):
                for item in chunk.get("content", []):
                    if item.get("type") == "text" and item.get("text"):
                        if first_output is None:
                            first_output = time.perf_counter()
                        chunks.append(item["text"])
        ended = time.perf_counter()
        return {
            "text": "".join(chunks),
            "elapsed_ms": round((ended - started) * 1000, 3),
            "first_output_ms": (
                round((first_output - started) * 1000, 3)
                if first_output is not None
                else None
            ),
        }

    def close(self):
        self._context.__exit__(None, None, None)


def run(args):
    tasks = read_jsonl(args.tasks)
    route_ids = json.loads(args.route_ids)
    system_prompt = Path(args.prompt).read_text(encoding="utf-8").strip()
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    completed = (
        {(item["repeat"], item["case_id"]) for item in read_jsonl(output_path)}
        if output_path.is_file()
        else set()
    )
    mode = "a" if output_path.exists() else "w"
    shared = None
    try:
        if args.runtime_mode == "warm":
            shared = Router(args.model, args.backend, args.max_num_tokens)
        with output_path.open(mode, encoding="utf-8", newline="\n") as output:
            for task in tasks:
                key = (task["repeat"], task["case_id"])
                if key in completed:
                    continue
                runtime = shared or Router(
                    args.model, args.backend, args.max_num_tokens
                )
                raw_text = ""
                error_text = None
                generation = {"elapsed_ms": 0.0, "first_output_ms": None}
                try:
                    generation = runtime.generate(system_prompt, task["router_input"])
                    raw_text = generation["text"]
                    predicted = parse_unique_route(raw_text, route_ids) or "GENERAL"
                except Exception as error:  # noqa: BLE001 - mirrors app fallback
                    predicted = "GENERAL"
                    error_text = f"{type(error).__name__}: {error}"
                finally:
                    load_elapsed_ms = runtime.load_elapsed_ms
                    if shared is None:
                        runtime.close()
                append_jsonl(
                    output,
                    {
                        "case_id": task["case_id"],
                        "repeat": task["repeat"],
                        "predicted_route_id": predicted,
                        "raw_output": raw_text,
                        "error": error_text,
                        "model_load_elapsed_ms": load_elapsed_ms,
                        "route_elapsed_ms": generation["elapsed_ms"],
                        "first_output_elapsed_ms": generation["first_output_ms"],
                    },
                )
    finally:
        if shared is not None:
            shared.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tasks", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--prompt", required=True, type=Path)
    parser.add_argument("--route-ids", required=True)
    parser.add_argument("--backend", choices=("cpu", "gpu"), required=True)
    parser.add_argument("--max-num-tokens", type=int, required=True)
    parser.add_argument("--runtime-mode", choices=("warm", "cold"), required=True)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
