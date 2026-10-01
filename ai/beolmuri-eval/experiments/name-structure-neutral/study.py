"""Six checkpointed runs: three neutral bundles × two prompt structures.

Default invocation only describes the plan. Generation requires the run subcommand.
"""
import argparse
import copy
import json
from pathlib import Path
import time
from types import SimpleNamespace
import uuid
from beolmuri_eval.evaluation import load_plan
from beolmuri_eval.runner import create_run, run, compare
from beolmuri_eval.storage import atomic_json, read_json, records
from beolmuri_eval.config import repository, digest, source_sha
from beolmuri_eval.metrics import summarize, compare_results
from beolmuri_eval.seeds import POLICY

CONFIG = Path(__file__).with_name('config.yaml')


def plans():
    document = load_plan(CONFIG).document
    return [load_plan(CONFIG, variant=v) for v in document['variants']]


def fingerprint():
    return digest({'source':source_sha(repository()), 'plans':[
        {name:digest(content.hex()) for name, (_,content) in p.files.items()} for p in plans()]})


def report(directory):
    state = read_json(directory/'study.json')
    grouped = {'identity-statement': [], 'response-action': []}
    comparisons = {}
    for bundle in 'abc':
        paths = [Path(state['runs'][f'{style}-{bundle}']) for style in grouped]
        comparisons[bundle] = compare(*paths)
        for style, path in zip(grouped, paths):
            for row in records(path):
                row = copy.deepcopy(row)
                row['key'] = bundle + '-' + row['key']
                grouped[style].append(row)
    if any(len(rows) != 60 for rows in grouped.values()):
        raise ValueError('study requires exactly 60 completed responses per structure')
    value = {'bundles': comparisons, 'summaries': {s:summarize(r,60) for s,r in grouped.items()},
             'paired': compare_results(*grouped.values()),
             'scope': 'wrong-name-only; three fixed neutral bundles; inspect recorded per-case seeds; no normal-name controls'}
    atomic_json(directory/'comparison.json', value)
    return value


def main():
    parser = argparse.ArgumentParser(description='중립 글 3종 이름 평가: 기본 동작은 계획 출력')
    parser.add_argument('command', nargs='?', choices=('plan','run','resume','report'), default='plan')
    parser.add_argument('--directory', type=Path, help='resume/report의 기존 실험 폴더')
    parser.add_argument('--model')
    parser.add_argument('--litert-python')
    parser.add_argument('--codex', default='codex')
    args = parser.parse_args()
    if args.command == 'plan':
        print(json.dumps({'generation_started':False, 'runs':[
            {'variant':p.variant, 'cases':len(p.cases), 'repeats':p.repeats,
             'base_seed':p.document['run'].get('seed',0), 'seed_policy':POLICY, 'max_num_tokens':p.max_num_tokens} for p in plans()],
            'per_structure':60, 'total':120}, ensure_ascii=False, indent=2))
        return
    if args.command in ('resume','report'):
        if args.directory is None: parser.error('--directory is required')
        directory = args.directory.resolve()
        state = read_json(directory/'study.json')
    else:
        directory = repository()/'ai/beolmuri-eval/.artifacts/neutral-studies'/(
            time.strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:8])
        directory.mkdir(parents=True)
        state = {'runs':{}, 'variants':[p.variant for p in plans()], 'fingerprint':fingerprint()}
        atomic_json(directory/'study.json', state)
    if args.command != 'report':
        print('실험 기록: '+str(directory), flush=True)
        for variant in state['variants']:
            if state['fingerprint'] != fingerprint():
                raise ValueError('study inputs or execution source changed; start a new study')
            existing = variant in state['runs']
            if existing:
                path = Path(state['runs'][variant])
            else:
                options = SimpleNamespace(config=str(CONFIG), variant=variant, repeats=None,
                    limit_pairs=None, timeout=None, model=args.model,
                    litert_python=args.litert_python, codex=args.codex)
                path = create_run(options)
                state['runs'][variant] = str(path)
                atomic_json(directory/'study.json', state)
            result = run(path, resume=existing)
            if not result['complete']:
                raise RuntimeError('incomplete run; inspect checkpoint and resume the study')
    print(json.dumps(report(directory), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
