"""Product checkpoint API: fresh-process restore and rejected-file recovery.

Greedy visible-output equality is the criterion, not a latency benchmark or a
bitwise-logits claim. All fixtures are synthetic and use the actual app composer.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time


def digest(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def run(binary, model, directory, scenario, mode):
    start = time.monotonic()
    with (directory / f'{mode}.log').open('wb') as log:
        process = subprocess.Popen([str(binary), mode, str(model), str(directory), scenario], stdout=log, stderr=subprocess.STDOUT)
        while process.poll() is None:
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                print(f'heartbeat {scenario}/{mode} elapsed={time.monotonic()-start:.0f}s', flush=True)
                if time.monotonic() - start > 300:
                    process.kill()
                    process.wait()
                    raise RuntimeError(f'{scenario}/{mode} exceeded diagnostic deadline')
    if process.returncode:
        raise RuntimeError(f'{scenario}/{mode}: exit={process.returncode}; inspect the corresponding log')
    return json.loads((directory / f'{mode}.json').read_text())


def main():
    binary, model, root = [Path(p).resolve() for p in sys.argv[1:]]
    root.mkdir()
    report = {'model_sha256': digest(model), 'worker_sha256': digest(binary), 'cases': []}
    for scenario in ['next', 'dynamic', 'boundary', 'cancelled', 'failed']:
        directory = root / scenario
        directory.mkdir()
        print(f'START {scenario}', flush=True)
        run(binary, model, directory, scenario, 'seed')
        saved = digest(directory / 'cache' / 'latest.kv')
        restored = run(binary, model, directory, scenario, 'restore')
        cold = run(binary, model, directory, scenario, 'cold')
        checks = {'restored_matches_cold': restored['output'] == cold['output'],
                  'cache_preserved': saved == digest(directory / 'cache' / 'latest.kv')}
        if scenario == 'cancelled':
            checks['busy_save_rejected'] = not (directory / 'must-not-exist.bin' / 'latest.kv').exists()
        else:
            warm = json.loads((directory / 'warm.json').read_text())
            checks['same_session_after_save_matches_cold'] = warm['output'] == cold['output']
        if scenario == 'next':
            for mode in ['corrupt', 'incompatible', 'truncated', 'old-format']:
                recovered = run(binary, model, directory, scenario, mode)
                checks[mode + '_recovers_cold_output'] = recovered['output'] == cold['output']
        report['cases'].append({'scenario': scenario, 'checks': checks})
        (root / 'results.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report['cases'][-1]), flush=True)
        if not all(checks.values()):
            raise RuntimeError('Checkpoint correctness mismatch')


if __name__ == '__main__':
    main()
