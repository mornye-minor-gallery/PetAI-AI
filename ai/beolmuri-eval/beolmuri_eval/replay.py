"""Replay recorded model requests verbatim through the harness native adapter.

This is a transport-reproduction experiment, not the app's Swift prompt path.
No persona assembly, seed derivation, output cleanup policy or retry is added.
"""
import json
from pathlib import Path
import time

import jsonschema

from . import process
from .config import digest, file_sha
from .doctor import inspect_environment
from .process import Worker, heartbeat
from .storage import atomic_json, read_json, records, run_lock

SAMPLING = {
    'type': 'object', 'additionalProperties': False,
    'required': ['temperature', 'top_k', 'top_p', 'max_output_tokens', 'thinking', 'filter_channel_content_from_kv_cache'],
    'properties': {
        'temperature': {'type': 'number', 'minimum': 0},
        'top_k': {'type': 'integer', 'minimum': 1},
        'top_p': {'type': 'number', 'minimum': 0, 'maximum': 1},
        'max_output_tokens': {'type': 'integer', 'minimum': 1},
        'thinking': {'type': 'boolean'},
        'filter_channel_content_from_kv_cache': {'type': 'boolean'},
    },
}
REQUEST = {
    'type': 'object',
    'required': ['id', 'system_prompt', 'user_prompt', 'seed', 'max_num_tokens', 'sampling'],
    'properties': {
        'id': {'type': 'string', 'pattern': '^[A-Za-z0-9][A-Za-z0-9._-]*$'},
        'system_prompt': {'type': 'string'},
        'user_prompt': {'type': 'string', 'minLength': 1},
        'seed': {'type': 'integer', 'minimum': 0, 'maximum': 2147483647},
        'max_num_tokens': {'type': 'integer', 'minimum': 1, 'maximum': 2147483647},
        'sampling': SAMPLING,
    },
}


def load_requests(path):
    rows, seen = [], set()
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip(): continue
        try:
            row = json.loads(line)
            json.dumps(row, allow_nan=False)
            jsonschema.validate(row, REQUEST)
            if row['id'] in seen: raise ValueError('duplicate id')
            if row['sampling']['max_output_tokens'] > row['max_num_tokens']:
                raise ValueError('output reservation exceeds context')
            seen.add(row['id']); rows.append(row)
        except (ValueError, jsonschema.ValidationError) as error:
            raise ValueError(f'{path}:{number}: {error}') from error
    if not rows: raise ValueError('empty replay input')
    if len({r['max_num_tokens'] for r in rows}) != 1:
        raise ValueError('one replay run requires one context capacity')
    return rows


def _environment(model, litert_python):
    report = inspect_environment(model, litert_python)
    if not report['ready']:
        failed = [c for c in report['checks'] if c['status'] == 'fail']
        raise RuntimeError(f'doctor failed: {failed}')
    values = {c['name']: c['detail'] for c in report['checks']}
    return {'model': values['deployment_model'], 'litert_python': values['litert_python'],
            'runtime': {k: values['litert_native_library'][k] for k in ('version', 'backend')},
            'mobile_parity': report['runtime_parity']}


def replay_summary(directory):
    manifest = read_json(Path(directory) / 'manifest.json')
    saved = records(directory)
    completed = sum(r['status'] == 'completed' for r in saved)
    return {'planned': len(manifest['requests']), 'completed': completed,
            'failed': sum(r['status'] == 'failed' for r in saved),
            'complete': completed == len(manifest['requests']),
            'scope': 'verbatim-request-replay; app prompt pipeline not exercised'}


def run_replay(requests_path, output, model=None, litert_python=None, *, timeout=180, resume=False):
    if timeout <= 0: raise ValueError('timeout must be positive')
    requests_path, output = Path(requests_path).resolve(), Path(output).resolve()
    requests = load_requests(requests_path)
    environment = _environment(model, litert_python)
    sources = {name: file_sha(Path(__file__).with_name(name)) for name in
               ('replay.py', 'native_worker.py', 'process.py', 'storage.py', 'config.py', 'doctor.py')}
    fingerprint = digest({'requests': requests, 'environment': environment, 'sources': sources, 'timeout': timeout})
    if not resume: output.mkdir(parents=True, exist_ok=False)
    with run_lock(output):
        if resume:
            if read_json(output / 'manifest.json')['fingerprint'] != fingerprint:
                raise ValueError('replay input, environment or source changed; use a new output directory')
        else:
            atomic_json(output / 'manifest.json', {'kind': 'prompt-replay', 'fingerprint': fingerprint,
                        'requests_file': str(requests_path), 'requests': requests,
                        'requests_file_sha256': file_sha(requests_path), 'source_hashes': sources,
                        'timeout_seconds': timeout, 'created_at': time.time(), **environment})
        pending = [r for r in requests if not (output/'records'/f"{r['id']}.json").exists()
                   or read_json(output/'records'/f"{r['id']}.json")['status'] != 'completed']
        if not pending: return replay_summary(output)
        (output / 'cancel.request').unlink(missing_ok=True)
        process.CANCEL_FILE = output / 'cancel.request'
        atomic_json(output / 'state.json', {'state': 'running', 'updated_at': time.time()})
        try:
            with Worker([environment['litert_python'], str(Path(__file__).with_name('native_worker.py'))], output/'native.log') as native:
                atomic_json(output/'load.json', native.call('load', timeout=timeout,
                            model=environment['model']['path'], cache_dir=str(output/'cache'),
                            max_num_tokens=requests[0]['max_num_tokens']))
                for request in pending:
                    count = replay_summary(output)['completed']
                    heartbeat(f"replay [{'=' * count}{'.' * (len(requests)-count)}] {count}/{len(requests)} · {request['id']}")
                    path = output/'records'/f"{request['id']}.json"
                    attempt = read_json(path)['attempt']+1 if path.exists() else 1
                    atomic_json(output/'state.json', {'state': 'running', 'request_id': request['id'],
                                'attempt': attempt, 'updated_at': time.time()})
                    row = {'id': request['id'], 'input': request, 'input_sha256': digest(request),
                           'attempt': attempt, 'status': 'failed'}
                    try:
                        native.call('start', timeout=timeout, system_prompt=request['system_prompt'],
                                    sampling=request['sampling'], seed=request['seed'], reserve_output=True)
                        generation = native.call('generate', timeout=timeout, message=request['user_prompt'])
                        raw = ''.join(generation['chunks'])
                        row.update(generation=generation, raw_text=raw, answer=raw.strip(), status='completed')
                    except BaseException as error:
                        row['error'] = f'{type(error).__name__}: {error}'
                        raise
                    finally:
                        atomic_json(output/'attempts'/request['id']/f'{attempt:03}.json', row)
                        atomic_json(path, row)
                        atomic_json(output/'summary.json', replay_summary(output))
            atomic_json(output/'state.json', {'state': 'completed', 'updated_at': time.time()})
        except BaseException as error:
            atomic_json(output/'state.json', {'state': 'interrupted' if isinstance(error, KeyboardInterrupt) else 'failed',
                        'error': str(error), 'updated_at': time.time()})
            raise
        finally:
            process.CANCEL_FILE = None
        return replay_summary(output)
