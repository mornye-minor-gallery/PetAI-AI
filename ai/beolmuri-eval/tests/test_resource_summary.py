import json
from pathlib import Path
import tempfile
import unittest
from beolmuri_eval.resource.summary import summarize_run
from beolmuri_eval.resource.protocol import sha256

class SummaryTests(unittest.TestCase):
 def test_incomplete_run_does_not_become_success(self):
  with tempfile.TemporaryDirectory() as temporary:
   root=Path(temporary)
   (root/'manifest.json').write_text(json.dumps({'run_id':'one','role':'work','config':{'ram_max_gap_ms':300,'power_window_ms':1000}}))
   (root/'device-state-final.json').write_text(json.dumps({'phase':'failed','pid':42}))
   result=summarize_run(root)
   self.assertFalse(result['complete'])
   self.assertEqual(result['power']['mean']['status'],'invalid')
   self.assertIsNone(result['power']['mean']['value'])
 def test_tampered_artifact_is_not_analyzable(self):
  with tempfile.TemporaryDirectory() as temporary:
   root=Path(temporary);(root/'raw').mkdir()
   (root/'manifest.json').write_text(json.dumps({'run_id':'one','role':'idle','config':{'ram_max_gap_ms':300,'power_window_ms':1000}}))
   (root/'device-state-final.json').write_text(json.dumps({'phase':'finished','pid':42}))
   (root/'raw/data.jsonl').write_text('{}\n')
   (root/'artifacts.json').write_text(json.dumps({'complete':True,'files':[{'path':'raw/data.jsonl','kind':'ram','bytes':3,'sha256':'0'*64}]}))
   result=summarize_run(root)
   self.assertFalse(result['complete'])
   self.assertTrue(any('hash' in reason for reason in result['reasons']))

class ComparisonScopeTests(unittest.TestCase):
 def test_different_recorder_scope_is_not_a_default_comparison(self):
  from unittest.mock import patch
  from beolmuri_eval.resource.compare import compare_runs
  with tempfile.TemporaryDirectory() as temporary:
   roots=[Path(temporary)/name for name in ('before','after')]
   for root in roots:
    root.mkdir()
    (root/'manifest.json').write_text(json.dumps(dict(config={},model={},generation={},inputs=[])))
    (root/'transport.json').write_text(json.dumps(dict(device='synthetic',expected_build_id='same')))
   summaries=[dict(complete=True,run_id=str(i),measurement_environment={'recorder_target_scope':scope},power={'mean':{'value':1}}) for i,scope in enumerate(('unrecorded','all_processes'))]
   with patch('beolmuri_eval.resource.compare.summarize_run',side_effect=summaries):
    with self.assertRaisesRegex(ValueError,'recorder_target_scope'):compare_runs(*roots)
