import json
import tempfile
from pathlib import Path
import unittest
import yaml
from beolmuri_eval.content import compile_content
from beolmuri_eval.evaluation import load_plan, default_config_path
from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from beolmuri_eval.process import Worker


class ContentTests(unittest.TestCase):
    def test_yaml_snapshot_and_shared_swift_composition(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            character = root / 'character.yaml'
            situation = root / 'situation.yaml'
            character.write_text('id: sample\nname: 검사자\npersona: |\n  친절하게 대답한다.\nexamples: []\n')
            situation.write_text('situation: 방에서 쉬고 있다.\nknowledge: 창문은 닫혀 있다.\n')
            content = compile_content(character, situation)
            cases = [dict(id=kind, pair_id='pair', kind=kind, character_name='검사자',
                          called_name=name, user_message=f'{name}, 안녕')
                     for kind, name in [('correct_name', '검사자'), ('wrong_name', '다른이')]]
            (root/'data.jsonl').write_text('\n'.join(json.dumps(c, ensure_ascii=False) for c in cases))
            document = yaml.safe_load(default_config_path().read_text())
            document['dataset'] = {'path':'data.jsonl', 'data_class':'synthetic'}
            document['variants'] = {'baseline': {'includePersona':True, 'includeSessionContext':False,
                'enforceCharacterName':False, 'memoryClassification':False,
                'content':{'character':'character.yaml', 'situation':'situation.yaml'}}}
            for key in ('rubric', 'schema'):
                document['judge'][key] = str((default_config_path().parent / document['judge'][key]).resolve())
            (root/'eval.yaml').write_text(yaml.safe_dump(document, allow_unicode=True))
            plan = load_plan(root/'eval.yaml')
            self.assertEqual(plan.configuration['dialogueContent'], content)
            (root/'snapshot').mkdir()
            plan.snapshot(root/'snapshot')
            self.assertEqual((root/'snapshot/inputs/character.yaml').read_bytes(), character.read_bytes())
            with Worker([str(swift_binary(repository()))], root/'worker.log') as worker:
                worker.call('validate', configuration=plan.configuration, characterName='검사자')
                result = worker.call('prepare', configuration=plan.configuration,
                                     characterName='검사자', userMessage='안녕')
                self.assertEqual(result['system_prompt'],
                    '## 캐릭터\n친절하게 대답한다.\n\n## 현재 상황\n방에서 쉬고 있다.\n\n## 현재 알고 있는 정보\n창문은 닫혀 있다.')
                self.assertEqual(result['configuration']['dialogueContent'], content)
                with self.assertRaises(RuntimeError):
                    worker.call('prepare', configuration=plan.configuration,
                                characterName='다른이', userMessage='안녕')

    def test_missing_or_malformed_character_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            (p/'s.yaml').write_text('situation: 대기 중\n')
            with self.assertRaises(FileNotFoundError): compile_content(p/'c.yaml', p/'s.yaml')
            (p/'c.yaml').write_text('id: test\nname: ""\npersona: 검사\n')
            with self.assertRaisesRegex(ValueError, 'name'):
                compile_content(p/'c.yaml', p/'s.yaml')
