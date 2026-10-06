from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from beolmuri_eval.runner import run
from beolmuri_eval.scenarios import load_scenarios, flatten_scenarios
from beolmuri_eval.storage import atomic_json, records, read_json
import json


class SessionWorker:
    prepares = []
    generated = 0
    fail_at = None

    def __init__(self,*args): pass
    def __enter__(self): return self
    def __exit__(self,*args): pass
    def call(self, operation, **kw):
        if operation == 'load': return {'load_ms':0}
        if operation == 'prepare':
            before = kw.get('sessionCheckpoint', {'clock':0})
            self.prepares.append((kw['userMessage'],before))
            return {'session_checkpoint':before,'model_input':{'messages':[
                        {'role':'system','text':'system'}, {'role':'user','text':kw['userMessage']}]},
                    'sampling':{},'world_info_seed':kw['worldInfoContext']['randomSeed']+before['clock']}
        if operation == 'generate':
            type(self).generated += 1
            if self.generated == self.fail_at: raise RuntimeError('interrupted generation')
            return {'chunks':['엘레나야']}
        if operation == 'start_input': return {'status':'started','message':kw['model_input']['messages'][-1]['text']}
        if operation == 'process': return {'visible_text':'엘레나야','status':'processed'}
        if operation == 'commit': return {'session_checkpoint':{'clock':kw['sessionCheckpoint']['clock']+2}}
        return {}


class MultiturnRunnerTests(unittest.TestCase):
    def make(self, root):
        scenarios=[]
        for name in ['a','b']:
            scenarios.append(dict(id=name,character_name='엘레나',turns=[
                dict(id='intro',user_message='공원 가자'),
                dict(id='probe',user_message='아영아',kind='wrong_name',called_name='아영')]))
        cases=flatten_scenarios(load_scenarios('\n'.join(json.dumps(s) for s in scenarios)))
        atomic_json(root/'manifest.json',dict(schema_version=3,run_id='test',timeout_seconds=2,cases=cases,repeats=2,
            variant='test',configuration={},runtime={'max_num_tokens':8096},memories=[],input_files={},
            litert_python='python',model={'path':'fixture'},judge={'codex':'codex'},base_seed=42))
        SessionWorker.prepares=[];SessionWorker.generated=0;SessionWorker.fail_at=None

    def test_resume_preserves_state_without_leaking_between_scenarios_or_repeats(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);self.make(root)
            SessionWorker.fail_at=2
            judgment={'label':'identity_maintained','incorrect_name_correction':None,'evidence':'엘레나','reason':'fixture'}
            with patch('beolmuri_eval.runner.Worker',SessionWorker),patch('beolmuri_eval.runner.grade',return_value=(judgment,{})),patch('beolmuri_eval.runner.verify_snapshot'),patch('beolmuri_eval.runner.validate_resume'):
                with self.assertRaisesRegex(RuntimeError,'interrupted'): run(root)
                self.assertEqual(records(root)[0]['status'],'completed')
                SessionWorker.fail_at=None
                result=run(root,resume=True)
                self.assertTrue(result['complete'])
                self.assertEqual(result['graded'],4)
                self.assertEqual(result['unscored_completed'],4)
                self.assertEqual(SessionWorker.generated,9) # 8 successful calls, one interrupted.
                self.assertEqual([x[1]['clock'] for x in SessionWorker.prepares],[0,2,2,0,2,0,2,0,2])
                run(root,resume=True)
                self.assertEqual(SessionWorker.generated,9)
                record=read_json(root/'records/a--intro-r0.json')
                record['session_after']['clock']=77
                atomic_json(root/'records/a--intro-r0.json',record)
                with self.assertRaisesRegex(ValueError,'checkpoint changed'): run(root,resume=True)
