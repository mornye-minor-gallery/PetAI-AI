"""Freeze synthetic inputs and explicit deployment settings before contacting a phone."""
import hashlib
import json
from pathlib import Path
from uuid import uuid4
from .config import load_config, validate_document


def inputs_from_config(path):
    config, paths=load_config(path)
    if config['target']!='inference' or config['profile']!='basic':
        raise ValueError('this executable currently supports inference/basic; other adapters are not yet implemented')
    if not config['bundle_id'].endswith('.resourcebench'):
        raise ValueError('benchmark bundle must be separate and end with .resourcebench')
    if json.loads(paths['initial_state'].read_text())!={}:
        raise ValueError('inference requires an empty synthetic initial state')
    models=json.loads(paths['model_manifest'].read_text())
    if models.get('backend')!='cpu' or len(models.get('models',[]))!=1:
        raise ValueError('current shared native runtime requires exactly one CPU language model')
    model=models['models'][0]
    if model.get('kind')!='language': raise ValueError('model kind must be language')
    source=(paths['model_manifest'].parent/model['path']).resolve()
    if not source.is_file(): raise ValueError('model file missing')
    if not isinstance(model.get('sha256'),str) or len(model['sha256'])!=64:
        raise ValueError('model SHA-256 is required')
    generation=json.loads(paths['generation_config'].read_text())
    expected={'context_tokens','max_output_tokens','temperature','top_k','top_p','thinking_enabled','conversation_mode'}
    if set(generation)!=expected or generation['conversation_mode'] not in ('fresh_per_input', 'cached_full_prompt'):
        raise ValueError('generation fields or conversation mode unsupported')
    json.dumps(generation,allow_nan=False)
    if (type(generation['thinking_enabled']) is not bool or
        any(type(generation[k]) is not int or generation[k]<=0 for k in ('context_tokens','max_output_tokens','top_k')) or
        generation['context_tokens']<=generation['max_output_tokens'] or generation['temperature']<0 or
        not 0<=generation['top_p']<=1): raise ValueError('invalid generation bounds')
    rows=[json.loads(line) for line in paths['fixture'].read_text().splitlines() if line.strip()]
    if not rows:
        raise ValueError('prepared inputs must not be empty')
    input_schema = json.loads((Path(__file__).resolve().parents[4] /
        'contracts/resource-benchmark/manifest.schema.json').read_text())['properties']['inputs']
    from jsonschema import Draft202012Validator
    errors = list(Draft202012Validator(input_schema).iter_errors(rows))
    if errors:
        raise ValueError('invalid prepared inputs: ' + errors[0].message)
    if len({r['id'] for r in rows})!=len(rows): raise ValueError('duplicate input id')
    return config,paths,model,source,generation,rows


def manifest(config, model, generation, rows, *, role, owner_id, measurement_mode='power'):
    value = dict(schema_version=1,run_id=str(uuid4()),owner_id=owner_id,role=role,config=config,
                measurement_mode=measurement_mode,
                model=dict(path=f"models/{model['sha256']}.litertlm",sha256=model['sha256']),
                generation=generation,inputs=rows)
    return validate_document("manifest", value)


def verify_model(path, expected, *, progress=lambda **kw: None):
    digest=hashlib.sha256(); total=path.stat().st_size; count=0
    with path.open('rb') as handle:
        while data:=handle.read(16*1024*1024):
            digest.update(data);count+=len(data)
            progress(stage='model_hash',completed_bytes=count,total_bytes=total)
    if digest.hexdigest()!=expected: raise ValueError('model SHA-256 mismatch')
