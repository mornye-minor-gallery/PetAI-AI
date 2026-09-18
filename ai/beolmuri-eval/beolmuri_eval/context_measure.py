"""Prepare and tokenize every variant/case without generation or remote grading."""
from pathlib import Path
import tempfile
from .config import repository, digest, source_sha
from .evaluation import load_plan
from .doctor import build, inspect_environment, swift_binary
from .metrics import numeric_summary
from .process import Worker, heartbeat
from .runner import check_environment
from .prompt_prepare import prepare_prompt


def measure_context(config, model=None, litert_python=None, codex="codex"):
    root = repository()
    initial = load_plan(config)
    plans = [load_plan(config, variant=name) for name in initial.document['variants']]
    build(root)
    environment = inspect_environment(model, litert_python, codex, judge_settings=initial.judge)
    detail = check_environment(environment)
    variants = {}
    with tempfile.TemporaryDirectory(prefix='beolmuri-context-') as temp:
        directory = Path(temp)
        with Worker([str(swift_binary(root))], directory/'swift.log') as swift, Worker(
                [detail['litert_python'], str(Path(__file__).with_name('native_worker.py'))], directory/'native.log') as native:
            native.call('load', timeout=180, model=detail['deployment_model']['path'],
                        cache_dir=str(directory/'cache'), max_num_tokens=initial.max_num_tokens)
            for plan in plans:
                rows = []
                for index, case in enumerate(plan.cases):
                    heartbeat(f'토큰 계측 {plan.variant} {index + 1}/{len(plan.cases)}')
                    prepared = prepare_prompt(swift, native, configuration=plan.configuration,
                                              case=case, history=plan.history, memories=plan.memories,
                                              max_num_tokens=plan.max_num_tokens, prompt_budget=plan.prompt_budget,
                                              timeout=plan.timeout_seconds)
                    native.call('start', system_prompt=prepared['system_prompt'], sampling=prepared['sampling'], seed=0, reserve_output=plan.prompt_budget is not None)
                    measured = native.call('measure', message=prepared['user_prompt'])
                    rows.append({'case_id': case['id'], **measured,
                                 'effective_output_ceiling': min(measured['available_output_tokens'], prepared['sampling']['max_output_tokens']),
                                 'history_stats': prepared['history_stats'], 'memory_stats': prepared['memory_stats'],
                                 'prompt_trace': prepared.get('prompt_trace'),
                                 'system_prompt_sha256': digest(prepared['system_prompt']),
                                 'user_prompt_sha256': digest(prepared['user_prompt'])})
                variants[plan.variant] = {
                    'history_sha256': digest(plan.history), 'memories_sha256': digest(plan.memories),
                    'input_tokens': numeric_summary([r['input_tokens'] for r in rows]),
                    'available_output_tokens': numeric_summary([r['available_output_tokens'] for r in rows]),
                    'cases': rows}
    return {'measurement_only': True, 'generation_verified': False,
            'model_sha256': detail['deployment_model']['sha256'], 'source_sha256': source_sha(root),
            'runtime': {'version': detail['litert_native_library']['version'], 'backend': 'gpu',
                        'max_num_tokens': initial.max_num_tokens}, 'prompt_budget': initial.prompt_budget, 'variants': variants}
