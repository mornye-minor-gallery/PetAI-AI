import tempfile
from pathlib import Path
import unittest
from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from beolmuri_eval.process import Worker


class PersonaProvisioningTests(unittest.TestCase):
    def test_missing_content_fails_before_inference_and_explicit_content_works(self):
        config = {'includePersona': True, 'includeSessionContext': False,
                  'enforceCharacterName': False, 'memoryClassification': False}
        with tempfile.TemporaryDirectory() as tmp, Worker(
            [str(swift_binary(repository()))], Path(tmp) / 'worker.log'
        ) as worker:
            for operation in ('validate', 'prepare'):
                with self.assertRaisesRegex(RuntimeError, 'notConfigured'):
                    worker.call(operation, configuration=config, userMessage='안녕')
            configured = {**config, 'personaCore': '{{char}}는 검사 전용 캐릭터다.'}
            worker.call('validate', configuration=configured)
            result = worker.call('prepare', configuration=configured,
                                 characterName='검사자', userMessage='안녕')
            self.assertEqual(result['system_prompt'], '검사자는 검사 전용 캐릭터다.')
            self.assertEqual(result['configuration'], configured)
            worker.call('prepare', configuration={**config, 'includePersona': False}, userMessage='안녕')
