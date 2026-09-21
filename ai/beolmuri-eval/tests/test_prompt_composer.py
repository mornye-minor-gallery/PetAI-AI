"""Exercise the worker adapter against the pre-refactor Swift output fixtures."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from persona_worker import Worker


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

    def test_worker_reports_explicit_core_and_shared_layout(self):
        with tempfile.TemporaryDirectory() as tmp, Worker(
            [str(swift_binary(repository()))], Path(tmp) / 'worker.log'
        ) as worker:
            result = worker.call('prepare', configuration={
                'includePersona': True, 'includeSessionContext': False,
                'enforceCharacterName': False, 'memoryClassification': False},
                characterName='검사자', userMessage='현재 질문')
            self.assertEqual(result['system_prompt'], '검사자는 검사 전용 캐릭터다.')
            self.assertTrue(result['user_prompt'].endswith('현재 질문'))
            self.assertEqual(result['prompt_trace']['userBytes'], len(result['user_prompt'].encode()))
