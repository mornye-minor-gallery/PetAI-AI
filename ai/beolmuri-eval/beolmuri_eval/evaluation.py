"""Validated, file-backed evaluation plans and immutable run inputs."""
from dataclasses import dataclass
import json
from pathlib import Path
import hashlib
import jsonschema
import yaml
from .config import repository
from .metrics import LABELS


def default_config_path():
    return repository() / "ai/beolmuri-eval/configs/name-identity.yaml"


def schema_path(name):
    return repository() / "ai/beolmuri-eval/schemas" / name


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key: {key}")
        result[key] = value
    return result


class StrictLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node):
    loader.flatten_mapping(node)
    return unique_fields((loader.construct_object(key), loader.construct_object(value))
                         for key, value in node.value)


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def validate(value, schema, location):
    try:
        jsonschema.validate(value, schema)
    except jsonschema.ValidationError as error:
        field = ".".join(str(part) for part in error.absolute_path)
        raise ValueError(f"{location}: {field}: {error.message}") from error


def load_dataset(path, *, content=None):
    path = Path(path)
    schema = json.loads(schema_path("name-case.schema.json").read_text())
    rows, ids, pairs = [], set(), {}
    text = path.read_text(encoding="utf-8") if content is None else content.decode("utf-8")
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        location = f"{path}:{line_number}"
        try:
            row = json.loads(line, object_pairs_hook=unique_fields)
            validate(row, schema, location)
            if any(not row[key].strip() for key in ("character_name", "called_name", "user_message")):
                raise ValueError("names and utterances must not be blank")
            if row["id"] in ids:
                raise ValueError(f"duplicate id: {row['id']}")
            same = row["character_name"] == row["called_name"]
            if same != (row["kind"] == "correct_name"):
                raise ValueError("called_name conflicts with case kind")
        except (ValueError, TypeError) as error:
            raise ValueError(f"{location}: {error}") from error
        ids.add(row["id"])
        rows.append(row)
        pairs.setdefault(row["pair_id"], []).append(row)
    if not rows:
        raise ValueError(f"{path}: dataset is empty")
    for pair_id, members in pairs.items():
        if len(members) != 2 or {r["kind"] for r in members} != {"wrong_name", "correct_name"}:
            raise ValueError(f"{path}: pair {pair_id} requires one wrong_name and one correct_name case")
        if len({r["character_name"] for r in members}) != 1:
            raise ValueError(f"{path}: pair {pair_id} must use the same character")
    return rows


@dataclass
class EvaluationPlan:
    config_path: Path
    document: dict
    cases: list
    variant: str
    configuration: dict
    repeats: int
    timeout_seconds: int
    judge: dict
    files: dict
    history: list
    memories: list
    max_num_tokens: int

    @property
    def prompt_budget(self):
        return self.document.get("prompt_budget")

    def snapshot(self, directory):
        inputs = Path(directory) / "inputs"
        inputs.mkdir()
        metadata = {}
        # Publish manifest only after all input files exist. Resume reads these
        # copies, never mutable external paths from the original YAML file.
        for name, (original, content) in self.files.items():
            (inputs / name).write_bytes(content)
            metadata[name] = {"source": str(original), "sha256": hashlib.sha256(content).hexdigest()}
        return metadata


def load_plan(path=None, *, variant=None, repeats=None, limit_pairs=None, timeout=None):
    path = Path(path or default_config_path()).expanduser().resolve()
    raw = path.read_bytes()
    try:
        document = yaml.load(raw, Loader=StrictLoader)
    except (yaml.YAMLError, ValueError) as error:
        raise ValueError(f"{path}: {error}") from error
    validate(document, json.loads(schema_path("evaluation.schema.json").read_text()), path)
    if "prompt_budget" in document:
        if "runtime" not in document or document["prompt_budget"]["output_tokens"] >= document["runtime"]["max_num_tokens"]:
            raise ValueError("prompt_budget requires explicit runtime capacity greater than output reservation")
    selected = variant if variant is not None else document["run"]["variant"]
    if selected not in document["variants"]:
        raise ValueError(f"{path}: unknown variant {selected!r}; choose {', '.join(document['variants'])}")
    repeat_count = document["run"]["repeats"] if repeats is None else repeats
    seconds = document["run"]["timeout_seconds"] if timeout is None else timeout
    if type(repeat_count) is not int or not 1 <= repeat_count <= 100:
        raise ValueError("repeats must be an integer between 1 and 100")
    if type(seconds) is not int or seconds < 1:
        raise ValueError("timeout must be a positive integer")
    def resolve(value):
        return (path.parent / Path(value).expanduser()).resolve()
    data_path = resolve(document["dataset"]["path"])
    data = data_path.read_bytes()
    cases = load_dataset(data_path, content=data)
    pair_ids = list(dict.fromkeys(row["pair_id"] for row in cases))
    if limit_pairs is not None:
        if type(limit_pairs) is not int or not 1 <= limit_pairs <= len(pair_ids):
            raise ValueError(f"limit-pairs must be between 1 and {len(pair_ids)}")
        selected_pairs = set(pair_ids[:limit_pairs])
        cases = [row for row in cases if row["pair_id"] in selected_pairs]
    rubric_path = resolve(document["judge"]["rubric"])
    judge_schema_path = resolve(document["judge"]["schema"])
    rubric = rubric_path.read_bytes()
    schema_bytes = judge_schema_path.read_bytes()
    output_schema = json.loads(schema_bytes, object_pairs_hook=unique_fields)
    jsonschema.Draft202012Validator.check_schema(output_schema)
    properties = output_schema.get("properties", {})
    if (set(properties.get("label", {}).get("enum", [])) != set(LABELS)
            or not {"label", "incorrect_name_correction", "evidence", "reason"}.issubset(output_schema.get("required", []))):
        raise ValueError(f"{judge_schema_path}: schema must expose the four-label name-identity judgment contract")
    if not rubric.decode("utf-8").strip():
        raise ValueError("judge rubric must not be empty")
    judge = {k: document["judge"][k] for k in ("provider", "model", "reasoning_effort")}
    judge.update(rubric=rubric.decode("utf-8"), output_schema=output_schema)
    configuration = dict(document["variants"][selected])
    if "worldInfo" in configuration and "prompt_budget" not in document:
        raise ValueError("worldInfo requires prompt_budget and the native tokenizer path")
    history_file = configuration.pop("history_file", None)
    history = []
    files = {"config.yaml": (path, raw), "dataset.jsonl": (data_path, data),
             "judge.md": (rubric_path, rubric), "judge.schema.json": (judge_schema_path, schema_bytes)}
    if history_file is not None:
        history_path = resolve(history_file)
        history_bytes = history_path.read_bytes()
        history = json.loads(history_bytes, object_pairs_hook=unique_fields)
        if not isinstance(history, list) or not history:
            raise ValueError(f"{history_path}: history must be a nonempty list of exchanges")
        for exchange in history:
            if (not isinstance(exchange, dict) or set(exchange) != {"user", "assistant"}
                    or any(not isinstance(text, str) or not text.strip() for text in exchange.values())):
                raise ValueError(f"{history_path}: each exchange requires nonempty user and assistant text")
        files["history.json"] = (history_path, history_bytes)
    memories_file = configuration.pop("memories_file", None)
    memories = []
    if memories_file is not None:
        memory_path = resolve(memories_file)
        memory_bytes = memory_path.read_bytes()
        memories = json.loads(memory_bytes, object_pairs_hook=unique_fields)
        if (not isinstance(memories, list) or not 1 <= len(memories) <= 10
                or any(not isinstance(text, str) or not text.strip() for text in memories)):
            raise ValueError(f"{memory_path}: memories must contain 1–10 nonempty strings in retrieval rank order")
        files["memories.json"] = (memory_path, memory_bytes)
    return EvaluationPlan(path, document, cases, selected, configuration, repeat_count,
                          seconds, judge, files, history, memories,
                          document.get("runtime", {}).get("max_num_tokens", 4096))


def verify_snapshot(directory, metadata):
    required = {"config.yaml", "dataset.jsonl", "judge.md", "judge.schema.json"}
    if not required.issubset(metadata):
        raise ValueError("run input snapshot is incomplete")
    for name, expected in metadata.items():
        if name not in required | {"history.json", "memories.json"}:
            raise ValueError("unknown snapshot entry")
        actual = hashlib.sha256((Path(directory) / "inputs" / name).read_bytes()).hexdigest()
        if actual != expected["sha256"]:
            raise ValueError(f"run input snapshot changed: {name}")
