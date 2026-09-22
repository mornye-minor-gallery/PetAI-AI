"""Real shared Swift selection and serialization, using synthetic token measurements."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import yaml
from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from beolmuri_eval.evaluation import load_plan, schema_path, validate, default_config_path
from persona_worker import Worker

CONFIG = dict(includePersona=True, includeSessionContext=True, enforceCharacterName=True, memoryClassification=True)
WI = dict(tokenBudget=100, includeNames=False, entries=[
    dict(id='before', keys=['서울'], content='지식앞', position='before-character'),
    dict(id='top', keys=['서울'], content='노트앞', position='before-note'),
    dict(id='memory-only', keys=['비밀기억'], content='검색하면안됨')])

class WorldInfoTests(unittest.TestCase):
    def test_schema_and_loader_require_real_token_path(self):
        doc=copy.deepcopy(load_plan().document)
        doc['variants']={'wi':{**CONFIG,'worldInfo':WI}}
        doc['run']['variant']='wi'
        base=default_config_path().parent
        for container,key in [(doc['dataset'],'path'),(doc['judge'],'rubric'),(doc['judge'],'schema')]:
            container[key]=str((base/container[key]).resolve())
        with tempfile.TemporaryDirectory() as tmp:
            config=Path(tmp)/'config.yaml'
            config.write_text(yaml.safe_dump(doc,allow_unicode=True))
            self.assertEqual(load_plan(config).configuration['worldInfo'],WI)
            doc['runtime'] = {'max_num_tokens': 4096}
            config.write_text(yaml.safe_dump(doc,allow_unicode=True))
            with self.assertRaisesRegex(ValueError,'worldInfo requires prompt_budget'):
                load_plan(config)
        doc['variants']['wi']['worldInfo']={**WI,'recursive':True}
        with self.assertRaises(ValueError):
            validate(doc,json.loads(schema_path('evaluation.schema.json').read_text()),'test')

    def test_worker_selects_and_fuses_note_without_searching_edgemem(self):
        seen=[]
        def measure(r):
            seen.append(r)
            return 100 if r['measurement']=='measure_input' else len(r['text'])
        with tempfile.TemporaryDirectory() as tmp, Worker([str(swift_binary(repository()))],Path(tmp)/'swift.log') as worker:
            result=worker.call('prepare',configuration={**CONFIG,'worldInfo':WI,'authorsNote':{'defaults':{'text':'상기','depth':1}}},
                userMessage='서울 이야기',memories=['비밀기억'],tokenBudget={'memoryTokens':1000,'contextTokens':200,'outputTokens':100},
                measurerID='synthetic',measurement_handler=measure)
            self.assertEqual(result['configuration']['worldInfo']['entries'][0]['id'],'before')
            trace=result['prompt_trace']['worldInfo']
            selected=[e['id'] for e in trace['entries'] if e['reason']=='selected']
            self.assertEqual(selected,['before','top'])
            self.assertTrue(result['system_prompt'].startswith('지식앞\n\n'))
            self.assertIn('노트앞\n상기',result['user_prompt'])
            self.assertIn('비밀기억',result['user_prompt'])
            self.assertNotIn('검색하면안됨',result['system_prompt'])
            final=next(r['input'] for r in seen if r['measurement']=='measure_input')
            self.assertEqual(final['systemPrompt'],result['system_prompt'])
            self.assertEqual(final['userPrompt'],result['user_prompt'])

    def test_no_byte_fallback_and_unsupported_fields_are_not_silently_ignored(self):
        with tempfile.TemporaryDirectory() as tmp, Worker([str(swift_binary(repository()))],Path(tmp)/'swift.log') as worker:
            for settings,error in [(WI,'tokenMeasurerRequired'),({**WI,'recursive':True},'Unsupported World Info field')]:
                with self.assertRaisesRegex(RuntimeError,error):
                    worker.call('prepare',configuration={**CONFIG,'worldInfo':settings},userMessage='서울')
            result=worker.call('prepare',configuration=CONFIG,userMessage='질문')
            self.assertEqual(result['status'],'prepared')

    def test_ignore_wi_budget_never_bypasses_model_capacity(self):
        settings={'tokenBudget':1,'entries':[{'id':'constant','content':'지식','constant':True,'ignoreBudget':True}]}
        seen=[]
        def measure(r):
            seen.append(r)
            return 101 if r['measurement']=='measure_input' else len(r['text'])
        with tempfile.TemporaryDirectory() as tmp, Worker([str(swift_binary(repository()))],Path(tmp)/'swift.log') as worker:
            with self.assertRaisesRegex(RuntimeError,'exceeded'):
                worker.call('prepare',configuration={**CONFIG,'worldInfo':settings},userMessage='질문',
                    tokenBudget={'memoryTokens':0,'contextTokens':200,'outputTokens':100},measurerID='synthetic',measurement_handler=measure)
            self.assertTrue(any('지식' in r['input']['systemPrompt'] for r in seen if r['measurement']=='measure_input'))
