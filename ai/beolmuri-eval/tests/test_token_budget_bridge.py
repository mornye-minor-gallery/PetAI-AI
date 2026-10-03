"""Real Swift selection over a synthetic native measurement transport (no model)."""
from pathlib import Path
import tempfile
import unittest

from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from persona_worker import Worker
from beolmuri_eval.prompt_prepare import prepare_prompt


CONFIG = dict(includePersona=True, includeSessionContext=True,
              enforceCharacterName=True, memoryClassification=True, thinking=True)
BUDGET = dict(memoryTokens=7, contextTokens=100, outputTokens=30)


class TokenBudgetBridgeTests(unittest.TestCase):
    def test_runtime_adapter_forwards_swift_measurements_and_capacity(self):
        class Native:
            calls = []
            def call(self, operation, **payload):
                self.calls.append((operation, payload))
                if operation == 'count_tokens':
                    return {'tokens': 3}
                if operation == 'measure_input':
                    return {'input_tokens': 70, 'max_num_tokens': 100}
                raise AssertionError(operation)
        native = Native()
        with tempfile.TemporaryDirectory() as tmp, Worker(
                [str(swift_binary(repository()))], Path(tmp) / 'swift.log') as worker:
            result = prepare_prompt(worker, native, configuration=CONFIG,
                case={'character_name': '엘레나', 'user_message': '질문'}, history=[], memories=['기억'],
                max_num_tokens=100, prompt_budget={'memory_tokens': 7, 'output_tokens': 30})
            self.assertEqual(result['prompt_trace']['tokenBudget']['inputTokens'], 70)
            measured = next(payload for op, payload in native.calls if op == 'measure_input')
            self.assertEqual(measured['model_input'], result['model_input'])
            self.assertEqual(measured['sampling'], result['sampling'])

    def test_swift_selects_memories_and_checks_full_input_using_native_answers(self):
        measurements = []

        def measure(request):
            measurements.append(request)
            if request['measurement'] == 'count_tokens':
                text = request['text']
                if text.startswith('Use the following past user memories'):
                    return 11 if '- 둘째' in text else 7
                return 3
            self.assertEqual(request['measurement'], 'measure_input')
            self.assertTrue(request['sampling']['thinking'])
            self.assertEqual(request['sampling']['max_output_tokens'], 30)
            self.assertIn('첫째', request['input']['messages'][-1]['text'])
            self.assertNotIn('둘째', request['input']['messages'][-1]['text'])
            self.assertEqual([m['role'] for m in request['input']['messages']], ['system', 'user', 'system', 'user'])
            return 70

        with tempfile.TemporaryDirectory() as tmp, Worker(
                [str(swift_binary(repository()))], Path(tmp) / 'swift.log') as worker:
            result = worker.call('prepare', configuration=CONFIG, userMessage='엘레나야',
                                 memories=['첫째', '둘째'],
                                 history=[{'user': '안녕', 'assistant': '반가워'}],
                                 tokenBudget=BUDGET, measurerID='test-native', measurement_handler=measure)
        trace = result['prompt_trace']['tokenBudget']
        self.assertEqual(trace['inputTokens'], 70)
        self.assertEqual(trace['reservedOutputTokens'], 30)
        self.assertEqual(trace['memoryTokens'], 7)
        self.assertEqual(result['sampling']['max_output_tokens'], 30)
        self.assertEqual(result['memory_stats']['inserted_count'], 1)
        self.assertIsNone(result['memory_stats']['byte_budget'])
        parts = {r['id']: r['tokens'] for r in trace['sections']}
        self.assertEqual(parts['history'], 3)
        self.assertEqual(parts['memories'], 7)
        self.assertEqual(parts['currentMessage'], 3)
        self.assertGreater(len(measurements), 3)

    def test_measurement_failure_overflow_and_negative_do_not_fallback_or_desync(self):
        with tempfile.TemporaryDirectory() as tmp, Worker(
                [str(swift_binary(repository()))], Path(tmp) / 'swift.log') as worker:
            def broken(_):
                raise RuntimeError('tokenizer unavailable')
            for handler, error in [(broken, 'tokenizer unavailable'),
                                   (lambda q: 71 if q['measurement'] == 'measure_input' else 1, 'exceeded'),
                                   (lambda q: -1, 'invalidMeasurement')]:
                with self.subTest(error=error), self.assertRaisesRegex(RuntimeError, error):
                    worker.call('prepare', configuration=CONFIG, userMessage='질문',
                                tokenBudget=BUDGET, measurerID='test-native', measurement_handler=handler)
            # The error response was consumed, so the next normal request is usable.
            with self.assertRaisesRegex(RuntimeError, 'no native token measurer connected'):
                worker.call('prepare', configuration=CONFIG, userMessage='질문',
                            tokenBudget=BUDGET, measurerID='test-native')
            result = worker.call('prepare', configuration=CONFIG, userMessage='질문')
            self.assertEqual(result['status'], 'prepared')
