"""Validated, file-backed evaluation plans and immutable run inputs."""
from dataclasses import dataclass
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012
import json
import re
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
        world_schema = json.loads(schema_path("world-info.schema.json").read_text())
        registry = Registry().with_resource("https://beolmuri.invalid/schemas/world-info.schema.json",
            Resource.from_contents(world_schema, default_specification=DRAFT202012))
        jsonschema.Draft202012Validator(schema, registry=registry).validate(value)
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
    if document["dataset"].get("format", "name-cases") == "scenarios":
        from .scenarios import load_scenarios, flatten_scenarios
        if "kind" in document["dataset"]:
            raise ValueError("dataset.kind cannot remove turns from a scenario")
        cases = flatten_scenarios(load_scenarios(data.decode("utf-8")))
    else:
        cases = load_dataset(data_path, content=data)
    pair_ids = list(dict.fromkeys(row["pair_id"] for row in cases))
    if limit_pairs is not None:
        if type(limit_pairs) is not int or not 1 <= limit_pairs <= len(pair_ids):
            raise ValueError(f"limit-pairs must be between 1 and {len(pair_ids)}")
        selected_pairs = set(pair_ids[:limit_pairs])
        cases = [row for row in cases if row["pair_id"] in selected_pairs]
    if "kind" in document["dataset"]:
        cases = [row for row in cases if row["kind"] == document["dataset"]["kind"]]
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
    if ("worldInfo" in configuration or "retrieval" in configuration) and "prompt_budget" not in document:
        raise ValueError("worldInfo requires prompt_budget and the native tokenizer path")
    history_file = configuration.pop("history_file", None)
    history = []
    files = {"config.yaml": (path, raw), "dataset.jsonl": (data_path, data),
             "judge.md": (rubric_path, rubric), "judge.schema.json": (judge_schema_path, schema_bytes)}
    content_source = configuration.pop("content", None)
    if content_source is not None:
        from .content import compile_content
        if "personaCore" in configuration:
            raise ValueError("content and personaCore cannot be combined")
        character_path = resolve(content_source["character"])
        situation_path = resolve(content_source["situation"])
        content = compile_content(character_path, situation_path)
        if any(case['character_name'] != content['name'] for case in cases):
            raise ValueError("dataset character_name must match the supplied character content")
        configuration["dialogueContent"] = content
        files["character.yaml"] = (character_path, character_path.read_bytes())
        files["situation.yaml"] = (situation_path, situation_path.read_bytes())
    if "retrieval" in configuration:
        if "dialogueContent" not in configuration:
            raise ValueError("retrieval requires character content")
        retrieval = dict(configuration["retrieval"])
        configuration["retrieval"] = retrieval
        configuration["dialogueContent"]["retrieval"] = {k: retrieval[k] for k in ("reactions", "worldLore")}
        directory = resolve(retrieval["directory"])
        retrieval["directory"] = str(directory)
        names = []
        if retrieval["reactions"]:
            names += ["reaction-frames.json", "reaction-vectors.f32"]
        if retrieval["worldLore"]:
            names += ["dialogue-lore.json"]
        for name in names:
            resource = directory / name
            files[name] = (resource, resource.read_bytes())
        from .config import file_sha
        for key in ("model", "tokenizer"):
            asset = resolve(retrieval[key])
            retrieval[key] = str(asset)
            retrieval[key + "_sha256"] = file_sha(asset)
    lorebooks = configuration.pop("lorebooks", {})
    if lorebooks:
        world = configuration.get("worldInfo")
        if world is None or "library" not in world:
            raise ValueError("lorebooks requires worldInfo.library bindings")
        # Copy nested settings: the original YAML document remains provenance.
        configuration["worldInfo"] = world = json.loads(json.dumps(world))
        books = world["library"]["books"]
        for name, filename in lorebooks.items():
            if name in books:
                raise ValueError(f"duplicate inline/file lorebook: {name}")
            book_path = resolve(filename)
            book_bytes = book_path.read_bytes()
            from .world_info import lorebook_payload
            books[name] = lorebook_payload(book_bytes)
            suffix = ".png" if book_bytes.startswith(b"\x89PNG") else ".json"
            if suffix == ".json":
                book = json.loads(book_bytes, object_pairs_hook=unique_fields)
                if not isinstance(book, dict):
                    raise ValueError("lorebook must be a JSON object; Swift validates the import format")
            snapshot_name = "lorebook-" + hashlib.sha256(name.encode()).hexdigest() + suffix
            files[snapshot_name] = (book_path, book_bytes)
        library = world["library"]
        bound = library["global"] + [book for names in library["characters"].values() for book in names]
        bound += [library[key] for key in ("chat", "persona") if key in library]
        if set(bound) - set(books):
            raise ValueError("lorebook binding references a missing book")
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
    if configuration.get("worldInfo", {}).get("rules", {}).get("vector") is not None:
        for case in cases:
            context = {**configuration.get("world_info_context", {}), **case.get("world_info_context", {})}
            if "vectorMatches" not in context:
                raise ValueError("vector retrieval requires explicit recorded vectorMatches for every turn")
    return EvaluationPlan(path, document, cases, selected, configuration, repeat_count,
                          seconds, judge, files, history, memories,
                          document.get("runtime", {}).get("max_num_tokens", 4096))


def verify_snapshot(directory, metadata):
    required = {"config.yaml", "dataset.jsonl", "judge.md", "judge.schema.json"}
    if not required.issubset(metadata):
        raise ValueError("run input snapshot is incomplete")
    for name, expected in metadata.items():
        if name not in required | {"history.json", "memories.json", "character.yaml", "situation.yaml",
                                   "reaction-frames.json", "reaction-vectors.f32", "dialogue-lore.json"} and not re.fullmatch(r"lorebook-[0-9a-f]{64}\.(json|png)", name):
            raise ValueError("unknown snapshot entry")
        actual = hashlib.sha256((Path(directory) / "inputs" / name).read_bytes()).hexdigest()
        if actual != expected["sha256"]:
            raise ValueError(f"run input snapshot changed: {name}")
