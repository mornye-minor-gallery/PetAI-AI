"""Measurement command must work without uncommitted experiment modules or fixtures."""
from pathlib import Path
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import patch
from beolmuri_eval.context_measure import measure_context

class MeasureContextCommandTests(TestCase):
    def test_native_measurement_aggregates_without_generation(self):
        plan = SimpleNamespace(document={'variants':{'test':{}}}, variant='test', judge={},
            history=[], memories=[], max_num_tokens=8096, configuration={}, prompt_budget=None,
            timeout_seconds=10, cases=[{'id':'example','character_name':'엘레나','user_message':'질문'}])
        calls = []
        class Worker:
            def __init__(self,*args): pass
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def call(self, operation, **payload):
                calls.append(operation)
                if operation in ('load','start'): return {}
                if operation=='prepare': return {'system_prompt':'system','user_prompt':'user',
                    'sampling':{'max_output_tokens':1024},'history_stats':{},'memory_stats':{},'prompt_trace':{}}
                if operation=='measure': return {'input_tokens':2000,'available_output_tokens':6096}
                raise AssertionError('Unexpected operation: '+operation)
        detail={'litert_python':'python','deployment_model':{'path':'model','sha256':'hash'},
                'litert_native_library':{'version':'test'}}
        with patch('beolmuri_eval.context_measure.load_plan', return_value=plan), \
             patch('beolmuri_eval.context_measure.build'), \
             patch('beolmuri_eval.context_measure.inspect_environment'), \
             patch('beolmuri_eval.context_measure.check_environment', return_value=detail), \
             patch('beolmuri_eval.context_measure.Worker', Worker), \
             patch('beolmuri_eval.context_measure.heartbeat'):
            result=measure_context(Path('synthetic.yaml'))
        self.assertEqual(calls,['load','prepare','start','measure'])
        self.assertEqual(result['variants']['test']['input_tokens'],
                         {'measured':1,'min':2000,'max':2000,'mean':2000})
        self.assertFalse(result['generation_verified'])
