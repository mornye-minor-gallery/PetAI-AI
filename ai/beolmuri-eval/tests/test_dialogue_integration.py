import json
from pathlib import Path
import tempfile
import unittest
from beolmuri_eval.scenarios import load_scenarios, flatten_scenarios
from beolmuri_eval.seeds import sample_seeds


class ScenarioTests(unittest.TestCase):
    def test_dialogue_then_name_probe(self):
        row = {'id': 'walk', 'character_name': '엘레나', 'turns': [
            {'id': 'intro', 'user_message': '안녕'},
            {'id': 'probe', 'user_message': '아영아', 'kind': 'wrong_name', 'called_name': '아영'}]}
        result = load_scenarios(json.dumps(row, ensure_ascii=False))
        cases = flatten_scenarios(result)
        self.assertEqual([r['kind'] for r in cases], ['dialogue', 'wrong_name'])
        self.assertEqual(cases[1]['id'], 'walk--probe')
        row['turns'][1]['id'] = 'intro'
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            load_scenarios(json.dumps(row))

    def test_seed_is_stable_and_domains_are_separate(self):
        a = sample_seeds(42, 'pair-a', 0, 'probe')
        self.assertEqual(a, sample_seeds(42, 'pair-a', 0, 'probe'))
        self.assertNotEqual(a['generation'], a['world_info_base'])
        b = sample_seeds(42, 'pair-a', 0, 'next')
        self.assertEqual(a['world_info_base'], b['world_info_base'])
        self.assertNotEqual(a['generation'], b['generation'])
        self.assertNotEqual(a, sample_seeds(42, 'pair-a', 1, 'probe'))

class PlanIntegrationTests(unittest.TestCase):
    def test_native_lorebook_snapshot_and_multiturn_plan(self):
        import yaml
        from beolmuri_eval.evaluation import load_plan, verify_snapshot
        original = load_plan()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            doc = original.document
            doc['dataset'] = dict(path='cases.jsonl', data_class='synthetic', format='scenarios')
            doc['judge']['rubric'] = str(original.files['judge.md'][0])
            doc['judge']['schema'] = str(original.files['judge.schema.json'][0])
            doc['variants']['baseline']['lorebooks'] = {'park':'park.json'}
            doc['variants']['baseline']['worldInfo'] = dict(tokenBudget=100, entries=[], library=dict(
                books={}, global_=[]))
            doc['variants']['baseline']['worldInfo']['library'] = {'books':{}, 'global':['park'], 'characters':{}, 'strategy':'even'}
            book = '{"entries":{"0":{"uid":0,"key":["공원"],"content":"분수가 있다."}}}'
            (root/'park.json').write_text(book)
            (root/'cases.jsonl').write_text(json.dumps(dict(id='walk',character_name='엘레나',turns=[dict(id='a',user_message='공원에 가자')]),ensure_ascii=False))
            (root/'config.yaml').write_text(yaml.safe_dump(doc,allow_unicode=True))
            plan = load_plan(root/'config.yaml')
            self.assertEqual(plan.configuration['worldInfo']['library']['books']['park'], book)
            self.assertEqual(plan.cases[0]['kind'], 'dialogue')
            run = root/'run';run.mkdir()
            files=plan.snapshot(run)
            verify_snapshot(run,files)
            filename=next(n for n in files if n.startswith('lorebook-'))
            (run/'inputs'/filename).write_text('{}')
            with self.assertRaisesRegex(ValueError,'changed'):
                verify_snapshot(run,files)

class WorkerCheckpointTests(unittest.TestCase):
    def test_sticky_and_clock_survive_commit_and_restore(self):
        from persona_worker import Worker
        from beolmuri_eval.doctor import swift_binary
        from beolmuri_eval.config import repository
        config=dict(includePersona=True,includeSessionContext=True,enforceCharacterName=True,memoryClassification=False,
            worldInfo=dict(tokenBudget=100,scanDepth=1,entries=[dict(id='park',keys=['공원'],content='파란 분수',rules=dict(sticky=8))]))
        def measure(r):
            return 100 if r['measurement']=='measure_input' else len(r['text'])
        with tempfile.TemporaryDirectory() as tmp, Worker([str(swift_binary(repository()))],Path(tmp)/'log') as worker:
            def prepare(message, **state):
                return worker.call('prepare',configuration=config,userMessage=message,worldInfoContext={'randomSeed':42},
                    tokenBudget=dict(memoryTokens=0,contextTokens=8096,outputTokens=1024),measurerID='fixture',measurement_handler=measure,**state)
            initial=prepare('공원')
            self.assertIn('파란 분수',initial['system_prompt'])
            payload=dict(configuration=config,sessionCheckpoint=initial['session_checkpoint'],userMessage='공원',assistantMessage='같이 가자',worldInfoTransaction=initial['world_info_transaction'])
            saved=worker.call('commit',**payload)['session_checkpoint']
            self.assertEqual(saved,worker.call('commit',**payload)['session_checkpoint'])
            follow=prepare('그렇구나',sessionCheckpoint=saved)
            self.assertEqual(follow['session_clock']['completed_messages'],2)
            self.assertEqual(follow['world_info_seed'],44)
            self.assertIn('파란 분수',follow['system_prompt'])
            fresh=prepare('그렇구나')
            self.assertNotIn('파란 분수',fresh['system_prompt'])
