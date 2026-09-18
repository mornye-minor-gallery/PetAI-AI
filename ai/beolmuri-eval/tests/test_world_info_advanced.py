import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from beolmuri_eval.process import Worker
from beolmuri_eval.world_info import control

CONFIG = dict(includePersona=True, includeSessionContext=True, enforceCharacterName=True, memoryClassification=True)

class WorldInfoAdvancedTests(unittest.TestCase):
    def test_recursive_selection_and_transaction_cross_worker_boundary(self):
        settings = dict(tokenBudget=200, rules=dict(recursive=True), entries=[
            dict(id='a', keys=['서울'], content='카페', rules=dict(sticky=8)),
            dict(id='b', keys=['카페'], content='연결됨', rules=dict(automationID='lore-discovered'))])
        with tempfile.TemporaryDirectory() as tmp, Worker([str(swift_binary(repository()))], Path(tmp)/'log') as worker:
            result = worker.call('prepare', configuration={**CONFIG, 'worldInfo':settings}, userMessage='서울',
                worldInfoContext={'trigger':'normal'}, tokenBudget=dict(memoryTokens=0,contextTokens=10000,outputTokens=1000),
                measurerID='synthetic', measurement_handler=lambda r: 100 if r['measurement']=='measure_input' else len(r['text']))
        self.assertIn('연결됨',result['system_prompt'])
        self.assertIn('a',result['world_info_transaction']['state']['sticky'])
        self.assertEqual(result['world_info_transaction']['automationIDs'],['lore-discovered'])
        self.assertEqual(result['session_clock']['completed_messages'],0)

    def test_lorebook_inspect_edit_and_export_use_swift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); book=root/'book.json'; entry=root/'entry.json'; output=root/'edited.json'
            original={'entries':{'0':{'uid':0,'content':'old','comment':'keep'}}}
            book.write_text(json.dumps(original))
            entry.write_text(json.dumps({'id':'demo.0','content':'new'}))
            args=SimpleNamespace(action='inspect',book=str(book),name='demo',entry=None,entry_id=None,output=None)
            self.assertEqual(control(args)['entries'][0]['content'],'old')
            args.action='upsert';args.entry=str(entry);args.output=str(output)
            self.assertEqual(control(args)['entries'][0]['content'],'new')
            self.assertEqual(json.loads(output.read_text())['entries']['0']['comment'],'keep')
            self.assertEqual(json.loads(book.read_text()),original)
            with self.assertRaises(FileExistsError): control(args)
