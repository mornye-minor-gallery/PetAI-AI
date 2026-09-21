import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from beolmuri_eval.replay import load_requests, run_replay


class ReplayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.path = self.root / 'requests.jsonl'
        self.output = self.root / 'run'
        self.row = {'id': 'sample', 'system_prompt': ' system\n', 'user_prompt': '\nuser  ',
                    'seed': 42, 'max_num_tokens': 8096,
                    'sampling': {'temperature': 0.7, 'top_k': 40, 'top_p': 1.0,
                                 'max_output_tokens': 256, 'thinking': False,
                                 'filter_channel_content_from_kv_cache': True}}
        self.write([self.row])
        self.environment = {'model': {'path': 'model', 'sha256': 'verified'},
                            'litert_python': 'python', 'runtime': {'version': '0.13.1', 'backend': 'gpu'}}

    def tearDown(self): self.temp.cleanup()
    def write(self, rows): self.path.write_text(''.join(json.dumps(r)+'\n' for r in rows))

    def test_invalid_or_duplicate_requests_fail_before_execution(self):
        self.assertEqual(load_requests(self.path), [self.row])
        for rows in ([self.row, self.row], [{**self.row, 'id': '../escape'}],
                     [{**self.row, 'seed': -1}], [{**self.row, 'sampling': {}}]):
            self.write(rows)
            with self.assertRaises(ValueError): load_requests(self.path)

    @patch('beolmuri_eval.replay._environment')
    @patch('beolmuri_eval.replay.Worker')
    def test_exact_payload_and_completed_resume_skips_generation(self, worker_type, environment):
        environment.return_value = self.environment
        native = worker_type.return_value.__enter__.return_value
        native.call.side_effect = lambda op, **kw: ({'chunks': [' answer ', '\n'], 'input_tokens': 262} if op == 'generate' else {})
        result = run_replay(self.path, self.output)
        self.assertTrue(result['complete'])
        calls = native.call.call_args_list
        start = next(c.kwargs for c in calls if c.args[0] == 'start')
        self.assertEqual(start['system_prompt'], self.row['system_prompt'])
        self.assertEqual(start['sampling'], self.row['sampling'])
        self.assertEqual(start['seed'], 42)
        self.assertEqual(next(c.kwargs['message'] for c in calls if c.args[0] == 'generate'), self.row['user_prompt'])
        record = json.loads((self.output / 'records/sample.json').read_text())
        self.assertEqual(record['input'], self.row)
        self.assertEqual(record['raw_text'], ' answer \n')
        native.call.reset_mock()
        self.assertTrue(run_replay(self.path, self.output, resume=True)['complete'])
        self.assertFalse(native.call.called)
        self.write([{**self.row, 'user_prompt': 'changed'}])
        with self.assertRaisesRegex(ValueError, 'changed'):
            run_replay(self.path, self.output, resume=True)

    @patch('beolmuri_eval.replay._environment')
    @patch('beolmuri_eval.replay.Worker')
    def test_failure_is_saved_and_not_silently_retried(self, worker_type, environment):
        environment.return_value = self.environment
        native = worker_type.return_value.__enter__.return_value
        native.call.side_effect = lambda op, **kw: (_ for _ in ()).throw(RuntimeError('inference failed')) if op == 'generate' else {}
        with self.assertRaisesRegex(RuntimeError, 'inference failed'):
            run_replay(self.path, self.output)
        self.assertEqual(json.loads((self.output/'records/sample.json').read_text())['status'], 'failed')
        self.assertEqual(json.loads((self.output/'state.json').read_text())['state'], 'failed')
        self.assertEqual(sum(c.args[0] == 'generate' for c in native.call.call_args_list), 1)
        native.call.side_effect = lambda op, **kw: {'chunks': ['restored']} if op == 'generate' else {}
        self.assertTrue(run_replay(self.path, self.output, resume=True)['complete'])
        self.assertEqual(json.loads((self.output/'records/sample.json').read_text())['attempt'], 2)
        self.assertEqual(json.loads((self.output/'attempts/sample/001.json').read_text())['status'], 'failed')
