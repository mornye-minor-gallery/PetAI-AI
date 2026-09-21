import tempfile
import unittest
from pathlib import Path
from beolmuri_eval.runner import compare
from beolmuri_eval.storage import atomic_json


class ComparisonTests(unittest.TestCase):
    def make_run(self, root, name, *, model='old', graded=True, case_id='probe'):
        directory = root/name
        case = dict(id=case_id, pair_id='p', kind='wrong_name', character_name='엘레나', called_name='아영', user_message='아영아')
        atomic_json(directory/'manifest.json', dict(run_id=name, cases=[case], repeats=1,
            model={'sha256':model}, configuration={'note':model}, judge={}, source_sha256=model))
        if graded:
            atomic_json(directory/'records'/f'{case_id}-r0.json', dict(key=f'{case_id}-r0', case=case, repeat=0, status='graded',
                generation={'processed':{'visible_text':'엘레나'}}, judgment={'label':'identity_maintained','incorrect_name_correction':None,'evidence':'엘레나','reason':'fixture'}))
        return directory

    def test_different_settings_are_reported_not_blocked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            a=self.make_run(root,'a');b=self.make_run(root,'b',model='new')
            result=compare(a,b)
            self.assertEqual(result['paired']['matched'],1)
            self.assertTrue(result['differences'])
            self.assertIsNone(result['control_correction_delta_percentage_points'])

    def test_missing_results_disable_full_pairing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            result=compare(self.make_run(root,'a'),self.make_run(root,'b',graded=False))
            self.assertFalse(result['paired']['available'])
            self.assertEqual(result['paired']['matched'],0)

    def test_corrupt_judgment_is_rejected(self):
        from beolmuri_eval.storage import read_json
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);a=self.make_run(root,'a');b=self.make_run(root,'b')
            record=read_json(b/'records/probe-r0.json')
            record['judgment']['incorrect_name_correction']=True
            atomic_json(b/'records/probe-r0.json',record)
            with self.assertRaisesRegex(ValueError,'wrong-name'):
                compare(a,b)

    def test_portable_export_scrubs_provenance_without_changing_dialogue(self):
        from beolmuri_eval.exporting import portable_comparison
        value={'differences':[
            {'field':'model.path','baseline':'/private/model','candidate':'/another/model'},
            {'field':'cases','baseline':[{'user_message':'/help 사용법 알려줘'}],'candidate':[]}]}
        result=portable_comparison(value)
        self.assertEqual(result['differences'][0]['baseline'],'<local-reference>')
        self.assertEqual(result['differences'][0]['candidate'],'<local-reference>')
        self.assertEqual(result['differences'][1]['baseline'][0]['user_message'],'/help 사용법 알려줘')

    def test_export_refuses_existing_directory(self):
        from beolmuri_eval.exporting import export
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);a=self.make_run(root,'a');b=self.make_run(root,'b')
            destination=root/'output';destination.mkdir()
            (destination/'old.jsonl').write_text('previous evidence')
            with self.assertRaises(FileExistsError):
                export(a,b,destination)
            self.assertEqual((destination/'old.jsonl').read_text(),'previous evidence')
