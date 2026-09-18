from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from beolmuri_eval.evaluation import load_plan
from beolmuri_eval.process import Worker
from beolmuri_eval.runner import run
from beolmuri_eval.storage import atomic_json, records


class MeasuredNative:
    started = None
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def call(self, operation, **payload):
        if operation == 'load':
            assert payload['max_num_tokens'] == 100
            return {'load_ms': 1}
        if operation == 'count_tokens': return {'tokens': 3}
        if operation == 'measure_prompt': return {'input_tokens': 70, 'max_num_tokens': 100}
        if operation == 'start':
            self.started = payload
            assert payload['reserve_output'] is True
            assert payload['sampling']['max_output_tokens'] == 30
            return {'status': 'started'}
        if operation == 'generate':
            assert self.started is not None
            return {'chunks': ['나는 엘레나야.'], 'input_tokens': 70}
        raise AssertionError(operation)


class TokenBudgetRunnerTests(unittest.TestCase):
    def test_runner_checkpoints_shared_swift_budget_and_uses_it_for_generation(self):
        native = MeasuredNative()
        def worker(args, log):
            return Worker(args, log) if args[0] == str(swift_binary(repository())) else native
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            plan = load_plan(variant='answer-only', limit_pairs=1)
            manifest = {'run_id': 'token-test', 'timeout_seconds': 5, 'cases': plan.cases[:1],
                        'repeats': 1, 'variant': plan.variant, 'configuration': plan.configuration,
                        'runtime': {'max_num_tokens': 100}, 'memories': ['산책을 좋아한다.'],
                        'prompt_budget': {'memory_tokens': 7, 'output_tokens': 30},
                        'litert_python': 'fake-native', 'model': {'path': 'unused'}, 'judge': {'codex': 'unused'}}
            atomic_json(directory / 'manifest.json', manifest)
            judgment = {'label': 'identity_maintained', 'incorrect_name_correction': None,
                        'evidence': '엘레나', 'reason': 'synthetic integration test'}
            with patch('beolmuri_eval.runner.Worker', worker), patch('beolmuri_eval.runner.grade', return_value=(judgment, {})):
                self.assertTrue(run(directory)['complete'])
            record = records(directory)[0]
            self.assertEqual(record['input']['prompt_trace']['tokenBudget']['inputTokens'], 70)
            self.assertEqual(record['input']['prompt_trace']['tokenBudget']['memoryTokens'], 3)
            self.assertEqual(record['input']['sampling'], native.started['sampling'])
