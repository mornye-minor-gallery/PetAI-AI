"""Exercise the real Swift worker; Python only transports files and explicit host inputs."""
import base64
import json
from pathlib import Path
import struct
import tempfile
import unittest
from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from persona_worker import Worker
from beolmuri_eval.world_info import lorebook_payload

CONFIG = dict(includePersona=True, includeSessionContext=True, enforceCharacterName=True, memoryClassification=True)

class NativeTextPortTests(unittest.TestCase):
    def test_standalone_note_clock_and_state_roundtrip(self):
        config = {**CONFIG, 'authorsNote': {'defaults': {'text': '{{isodate}} {{incvar::visits}} {{char}}', 'depth': 0}},
                  'authoredText': {'runtime': {'nowMilliseconds': 1767225600000, 'utcOffsetMinutes': 0}}}
        with tempfile.TemporaryDirectory() as tmp, Worker([str(swift_binary(repository()))], Path(tmp)/'worker.log') as worker:
            result = worker.call('prepare', configuration=config, characterName='Elena', userMessage='hi')
        self.assertIn('2026-01-01 1 Elena', result['user_prompt'])
        self.assertEqual(result['world_info_transaction']['text']['localVariables']['visits'], '1')
        self.assertEqual(result['configuration']['authoredText'], config['authoredText'])

    def test_png_transport_reaches_shared_swift_import(self):
        card = {'data': {'character_book': {'entries': [{'keys': ['park'], 'content': 'old oak', 'enabled': True}]}}}
        def chunk(name, payload):
            return struct.pack('>I', len(payload)) + name + payload + b'\0'*4
        png = b'\x89PNG\r\n\x1a\n' + chunk(b'tEXt', b'ccv3\0'+base64.b64encode(json.dumps(card).encode())) + chunk(b'IEND', b'')
        with tempfile.TemporaryDirectory() as tmp, Worker([str(swift_binary(repository()))], Path(tmp)/'worker.log') as worker:
            result = worker.call('world-info', action='inspect', name='card', book=lorebook_payload(png))
        self.assertEqual(result['entries'][0]['content'], 'old oak')

    def test_regex_registry_is_used_by_world_info(self):
        config = {**CONFIG, 'worldInfo': {'tokenBudget': 100, 'entries': [{'id': 'a', 'content': 'cat', 'constant': True}]},
                  'authoredText': {'regex': {'global': [{'findRegex': '/cat/', 'replaceString': 'dog', 'placement': [5]}]}}}
        with tempfile.TemporaryDirectory() as tmp, Worker([str(swift_binary(repository()))], Path(tmp)/'worker.log') as worker:
            result = worker.call('prepare', configuration=config, userMessage='hi',
                                 tokenBudget={'memoryTokens': 0, 'contextTokens': 8096, 'outputTokens': 1024},
                                 measurerID='fixture', measurement_handler=lambda r: 100 if r['measurement']=='measure_input' else len(r['text']))
        self.assertIn('dog', result['system_prompt'])
