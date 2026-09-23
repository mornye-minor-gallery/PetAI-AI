"""Author's Note integration through the real shared Swift worker; no inference."""
import json
from pathlib import Path
import tempfile
import unittest
import jsonschema
from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from persona_worker import Worker

CONFIG = dict(includePersona=True, includeSessionContext=True, enforceCharacterName=True,
              memoryClassification=True)

class AuthorsNoteTests(unittest.TestCase):
    def test_yaml_contract_accepts_settings_and_rejects_invalid_depth(self):
        from beolmuri_eval.evaluation import load_plan, validate, schema_path
        doc = load_plan().document
        doc['variants']['note'] = {**CONFIG, 'authorsNote': {'defaults': {'text':'상기', 'depth':1, 'interval':3},
                                                          'allowWorldInfoScan':True}}
        schema = json.loads(schema_path('evaluation.schema.json').read_text())
        validate(doc, schema, 'test')
        doc['variants']['note']['authorsNote']['defaults']['depth'] = -1
        with self.assertRaises(ValueError):
            validate(doc, schema, 'test')

    def test_note_uses_cumulative_history_and_is_counted_in_final_input(self):
        settings = {'defaults': {'text':'상기문', 'interval':3, 'depth':1}, 'allowWorldInfoScan': True}
        measured = []
        def measure(request):
            measured.append(request)
            return 70 if request['measurement'] == 'measure_input' else 3
        with tempfile.TemporaryDirectory() as tmp, Worker([str(swift_binary(repository()))], Path(tmp)/'swift.log') as worker:
            result = worker.call('prepare', configuration={**CONFIG, 'authorsNote':settings}, userMessage='현재질문',
                history=[{'user':f'과거{i}', 'assistant':'답변'} for i in range(11)], memories=['기억'],
                tokenBudget={'memoryTokens':20, 'contextTokens':100, 'outputTokens':30},
                measurerID='synthetic', measurement_handler=measure)
            self.assertEqual(result['configuration']['authorsNote'], settings)
            self.assertEqual(result['history_stats']['retained_messages'], 22)
            self.assertEqual(result['history_stats']['retained_turns'], 11)
            note = result['prompt_trace']['authorsNote']
            self.assertEqual(note['userMessageNumber'], 12)
            self.assertEqual(note['state'], 'active')
            self.assertTrue(result['user_prompt'].endswith('상기문\n\n[Current user message]\n현재질문'))
            measured_input = next(r['input'] for r in measured if r['measurement'] == 'measure_input')
            self.assertEqual(measured_input['userPrompt'], result['user_prompt'])
            self.assertTrue(any(s['id'] == 'authorsNote' for s in result['prompt_trace']['tokenBudget']['sections']))
            result = worker.call('prepare', configuration={**CONFIG, 'authorsNote':settings}, userMessage='현재질문',
                history=[{'user':'과거', 'assistant':'답변'} for _ in range(12)])
            self.assertEqual(result['prompt_trace']['authorsNote']['state'], 'notDue')
            self.assertNotIn('상기문', result['user_prompt'])

    def test_note_overflow_fails_without_silent_removal_and_worker_recovers(self):
        with tempfile.TemporaryDirectory() as tmp, Worker([str(swift_binary(repository()))], Path(tmp)/'swift.log') as worker:
            with self.assertRaisesRegex(RuntimeError, 'exceeded'):
                worker.call('prepare', configuration={**CONFIG, 'authorsNote':{'defaults':{'text':'상기문'}}},
                    userMessage='현재질문', tokenBudget={'memoryTokens':20, 'contextTokens':100, 'outputTokens':30},
                    measurerID='synthetic', measurement_handler=lambda r: 71 if r['measurement']=='measure_input' else 1)
            result = worker.call('prepare', configuration=CONFIG, userMessage='현재질문')
            self.assertEqual(result['status'], 'prepared')

    def test_depth_and_name_placement_do_not_count_memories_as_messages(self):
        with tempfile.TemporaryDirectory() as tmp, Worker([str(swift_binary(repository()))], Path(tmp)/'swift.log') as worker:
            for depth in (0,1,4):
                result = worker.call('prepare', configuration={**CONFIG, 'nameRulePlacement':'before-current',
                    'authorsNote':{'defaults':{'text':'상기문', 'depth':depth}}}, userMessage='현재질문',
                    history=[{'user':'이전질문1','assistant':'이전답변1'}, {'user':'이전질문2','assistant':'이전답변2'}], memories=['회수한기억'])
                text=result['user_prompt']
                self.assertEqual(text.count('상기문'),1)
                self.assertEqual(text.count(result['name_instruction']),1)
                self.assertIn('회수한기억',text)
                if depth==0: self.assertTrue(text.endswith('상기문'))
                elif depth==1:
                    self.assertLess(text.index('회수한기억'),text.index('상기문'))
                    self.assertLess(text.index('상기문'),text.index('현재질문'))
                else:
                    self.assertLess(text.index('이전질문1'),text.index('상기문'))
                    self.assertLess(text.index('상기문'),text.index('이전답변1'))
