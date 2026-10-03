"""Create ResourceBench inputs through the product's shared Swift composer."""
from copy import deepcopy
import json
from pathlib import Path

from .protocol import sha256


def _turns(path):
    path = Path(path)
    if path.suffix == ".jsonl":
        values = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    else:
        values = json.loads(path.read_text())
    if not isinstance(values, list) or not values:
        raise ValueError("dialogue turns must be a nonempty JSON array or JSONL file")
    seen = set()
    for row in values:
        if not isinstance(row, dict) or set(row) != {"id", "user_message", "history"}:
            raise ValueError("each dialogue turn requires only id, user_message and history")
        if not isinstance(row["id"], str) or not row["id"] or row["id"] in seen:
            raise ValueError("dialogue turn IDs must be unique nonempty strings")
        seen.add(row["id"])
        if not isinstance(row["user_message"], str) or not row["user_message"].strip():
            raise ValueError("dialogue user_message must be nonempty")
        if not isinstance(row["history"], list):
            raise ValueError("dialogue history must be an array")
        for exchange in row["history"]:
            if (not isinstance(exchange, dict) or set(exchange) != {"user", "assistant"}
                or not all(isinstance(exchange[key], str) and exchange[key].strip()
                           for key in ("user", "assistant"))):
                raise ValueError("history exchanges require nonempty user and assistant strings")
    return values


def compose_dialogue_fixture(content_path, turns_path, worker):
    """Return exact model inputs while leaving selection and layout in Swift."""
    content_path = Path(content_path).expanduser().resolve()
    content_bytes = content_path.read_bytes()
    content = json.loads(content_bytes)
    if not isinstance(content, dict) or not isinstance(content.get("name"), str) or not content["name"]:
        raise ValueError("dialogue content requires a character name")
    composed_content = deepcopy(content)
    composed_content.pop("retrieval", None)
    configuration = {
        "includePersona": True,
        "includeSessionContext": True,
        "enforceCharacterName": True,
        "memoryClassification": True,
        "nameRuleStyle": "response-action",
        "dialogueContent": composed_content,
        "thinking": False,
        "sampling": {"temperature": 0.7, "top_k": 40, "top_p": 1.0},
    }
    rows = []
    traces = []
    prefix_hash = None
    for turn in _turns(turns_path):
        result = worker.call(
            "prepare",
            configuration=configuration,
            characterName=content["name"],
            userMessage=turn["user_message"],
            history=turn["history"],
            memories=[],
        )
        messages = result["model_input"]["messages"]
        if len(messages) < 2 or messages[0]['role'] != 'system' or messages[-1]['role'] != 'user':
            raise ValueError("ResourceBench dialogue requires a fixed system prefix and final user message")
        system = messages[0]['text']
        user = messages[-1]['text']
        if not isinstance(system, str) or not isinstance(user, str) or not user:
            raise ValueError("Swift composer returned an invalid prepared input")
        current_hash = sha256(system.encode())
        if prefix_hash is None:
            prefix_hash = current_hash
        elif current_hash != prefix_hash:
            raise ValueError("system prefix changed between turns; invariant cache comparison is invalid")
        rows.append({"id": turn["id"], "system_prompt": system, "user_prompt": user,
                     "initial_messages": messages[1:-1]})
        sections = result.get("prompt_trace", {}).get("sections", [])
        traces.append({
            "id": turn["id"],
            "system_bytes": len(system.encode()),
            "user_bytes": len(user.encode()),
            "history_messages": len(turn["history"]) * 2,
            "system_sections": [row.get("source") for row in sections if row.get("placement") == "system"],
            "user_sections": [row.get("source") for row in sections if row.get("placement") == "user"],
        })
    provenance = {
        "content_source": str(content_path),
        "content_sha256": sha256(content_bytes),
        "retrieval_mode": "disabled_for_invariant_prefix_measurement",
        "system_prompt_sha256": prefix_hash,
        "system_prompt_bytes": len(rows[0]["system_prompt"].encode()),
        "turns": traces,
        "configuration": {**configuration, "dialogueContent": "canonical authored fields; retrieval excluded"},
    }
    return rows, provenance


def load_dialogue_fixture(content_path, turns_path, *, log_path):
    from ..doctor import swift_binary
    from ..config import repository
    from ..process import Worker

    executable = swift_binary(repository())
    if not executable.is_file():
        raise RuntimeError("Swift worker missing; run beolmuri-eval build")
    with Worker([str(executable)], Path(log_path)) as worker:
        return compose_dialogue_fixture(content_path, turns_path, worker)
