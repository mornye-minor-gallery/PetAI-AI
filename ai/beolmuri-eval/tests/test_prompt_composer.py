"""Exercise the worker adapter against the pre-refactor Swift output fixtures."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from beolmuri_eval.process import Worker


class SharedPromptComposerTests(unittest.TestCase):
    def test_worker_accepts_text_insertions_and_keeps_full_session_clock(self):
        with tempfile.TemporaryDirectory() as tmp, Worker(
            [str(swift_binary(repository()))], Path(tmp) / 'worker.log'
        ) as worker:
            config = {'includePersona': True, 'includeSessionContext': True,
                      'enforceCharacterName': False, 'memoryClassification': True}
            result = worker.call('prepare', configuration=config, userMessage='현재 질문',
                                 history=[{'user': f'질문 {i}', 'assistant': f'답변 {i}'} for i in range(40)],
                                 insertions=[{'id': 'note', 'source': 'authorsNote', 'text': '짧은 참고',
                                              'placement': 'afterCurrent', 'role': 'system', 'order': 100}])
            self.assertEqual(result['input_format'], 'systemAndUserText')
            self.assertTrue(result['user_prompt'].endswith('현재 질문\n\n짧은 참고'))
            self.assertEqual(len(result['history']), 20)
            self.assertEqual(result['session_clock']['current_user_message_number'], 41)
            self.assertEqual(result['session_clock']['current_message_number'], 81)
            note = result['prompt_trace']['insertions'][0]
            self.assertEqual(note['requestedRole'], 'system')
            self.assertEqual(note['deliveredRole'], 'user')

    def test_worker_preserves_frozen_inputs_and_reports_shared_layout(self):
        root = repository()
        fixture = root / 'ios/EdgeLLM/Tests/EdgeLLMTests/Resources/dialogue-prompt-baseline.json'
        cases = json.loads(fixture.read_text())['cases']
        with tempfile.TemporaryDirectory() as tmp, Worker(
            [str(swift_binary(root))], Path(tmp) / 'worker.log'
        ) as worker:
            for case in cases:
                request = dict(case['request'])
                request.pop('id')
                request.pop('operation')
                with self.subTest(configuration=request['configuration'], name=request['characterName']):
                    result = worker.call('prepare', **request)
                    for key, expected in case['sha256'].items():
                        self.assertEqual(hashlib.sha256(result[key].encode()).hexdigest(), expected)
                    trace = result['prompt_trace']
                    placement = request['configuration']['nameRulePlacement']
                    self.assertEqual(trace['nameRulePlacement'], placement)
                    self.assertEqual(trace['userBytes'], len(result['user_prompt'].encode()))
                    self.assertEqual('nameRule' in trace['systemSections'], placement == 'system')
                    self.assertEqual(result['memory_stats'], case['memory_stats'])
