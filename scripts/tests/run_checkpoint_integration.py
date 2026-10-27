"""Product checkpoint API: fresh-process restore and rejected-file recovery.

Greedy visible-output equality is the criterion, not a latency benchmark or a
bitwise-logits claim. All fixtures are synthetic and use the actual app composer.
"""
import hashlib
import argparse
import json
from pathlib import Path
import subprocess
import time


def digest(path):
    with path.open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def run(binary, model, directory, scenario, mode, backend, context):
    start = time.monotonic()
    with (directory / f'{mode}.log').open('wb') as log:
        process = subprocess.Popen([str(binary), mode, str(model), str(directory), scenario,
                                    backend, str(context)], stdout=log, stderr=subprocess.STDOUT)
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
    result = json.loads((directory / f'{mode}.json').read_text())
    if result.get('backend') != backend or result.get('contextTokens') != context or not result.get('output', '').strip():
        raise ValueError('Worker backend/context mismatch or empty output')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('model', type=Path)
    parser.add_argument('root', type=Path)
    parser.add_argument('--backend', choices=['cpu', 'gpu'], default='cpu')
    parser.add_argument('--context', type=int, default=8192)
    parser.add_argument('--scenarios', nargs='+', choices=['next', 'dynamic', 'boundary', 'cancelled', 'failed'],
                        default=['next', 'dynamic', 'boundary', 'cancelled', 'failed'])
    args = parser.parse_args()
    if args.context <= 0:
        parser.error('--context must be positive')
    binary, model, root = [p.resolve() for p in (args.binary, args.model, args.root)]
    root.mkdir()
    report = {'model_sha256': digest(model), 'worker_sha256': digest(binary),
              'backend': args.backend, 'context_tokens': args.context, 'cases': []}
    def execute(directory, scenario, mode):
        return run(binary, model, directory, scenario, mode, args.backend, args.context)
    for scenario in args.scenarios:
        directory = root / scenario
        directory.mkdir()
        print(f'START {scenario}', flush=True)
        execute(directory, scenario, 'seed')
        saved = digest(directory / 'cache' / 'latest.kv')
        restored = execute(directory, scenario, 'restore')
        reference = execute(directory, scenario, 'reference')
        cold = execute(directory, scenario, 'cold')
        checks = {'restored_matches_reference': restored['output'] == reference['output'],
                  'restored_matches_cold': restored['output'] == cold['output'],
                  'cache_preserved': saved == digest(directory / 'cache' / 'latest.kv')}
        if scenario == 'cancelled':
            checks['busy_save_rejected'] = not (directory / 'must-not-exist.bin' / 'latest.kv').exists()
        else:
            warm = json.loads((directory / 'warm.json').read_text())
            checks['same_session_after_save_matches_cold'] = warm['output'] == cold['output']
            checks['same_session_after_save_matches_reference'] = warm['output'] == reference['output']
        if scenario == 'next':
            for mode in ['corrupt', 'incompatible', 'truncated', 'old-format']:
                recovered = execute(directory, scenario, mode)
                checks[mode + '_recovers_cold_output'] = recovered['output'] == cold['output']
                if args.backend == 'gpu' and mode != 'incompatible':
                    checks[mode + '_failed_engine_rejected'] = recovered['failedEngineRejected']
        report['cases'].append({'scenario': scenario, 'checks': checks})
        (root / 'results.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report['cases'][-1]), flush=True)
    if not all(all(case['checks'].values()) for case in report['cases']):
        raise RuntimeError('Checkpoint correctness mismatch; inspect all recorded cases')


if __name__ == '__main__':
    main()
