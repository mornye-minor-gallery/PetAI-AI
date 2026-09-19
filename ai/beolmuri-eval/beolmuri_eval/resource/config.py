"""Strict experiment inputs. Paths are resolved relative to the configuration."""
import json
from pathlib import Path
import yaml
from jsonschema import Draft202012Validator, FormatChecker
from ..config import repository


def validate_document(name, document):
    try:
        json.dumps(document, allow_nan=False)
        path = repository() / 'contracts/resource-benchmark' / f'{name}.schema.json'
        validator = Draft202012Validator(json.loads(path.read_text()), format_checker=FormatChecker())
        errors = sorted(validator.iter_errors(document), key=lambda e: str(list(e.path)))
        if errors: raise ValueError('; '.join(f'{list(e.path)}: {e.message}' for e in errors))
    except (TypeError, OverflowError) as error:
        raise ValueError(str(error)) from error
    return document


def validate_config(document):
    validate_document('config', document)
    if document['profile'] == 'unity-memory' and document['target'] != 'unity':
        raise ValueError('unity-memory requires the Unity target')
    if document['ram_max_gap_ms'] < document['ram_sample_period_ms']:
        raise ValueError('ram_max_gap_ms is shorter than the requested period')
    if document['scenario'] == 'sustained' and document['reply_gap_ms'] != 0:
        raise ValueError('sustained requires reply_gap_ms=0')
    return document


def load_config(path):
    path = Path(path).expanduser().resolve()
    config = validate_config(yaml.safe_load(path.read_text()))
    paths = {}
    for key in ('fixture', 'initial_state', 'model_manifest', 'generation_config'):
        value = (path.parent / config[key]).resolve()
        if not value.is_file(): raise ValueError(f'{key}: file not found: {value}')
        paths[key] = value
    return config, paths
