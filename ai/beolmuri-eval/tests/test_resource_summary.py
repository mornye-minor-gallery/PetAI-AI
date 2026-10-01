import json
from pathlib import Path
import tempfile
import unittest
from beolmuri_eval.resource.summary import summarize_run
from beolmuri_eval.resource.protocol import sha256

class SummaryTests(unittest.TestCase):
 def test_inference_summary_does_not_require_power_trace(self):
  from resource_fixture import app_files, RUN, OWNER
  with tempfile.TemporaryDirectory() as temporary:
   root=Path(temporary);files=app_files();(root/'raw').mkdir()
   manifest={'run_id':RUN,'owner_id':OWNER,'role':'work','measurement_mode':'inference',
             'config':{'ram_max_gap_ms':300,'power_window_ms':1000},
             'inputs':[{'id':'turn','system_prompt':'system','user_prompt':'user'}],
             'generation':{'conversation_mode':'fresh_per_input'}}
   (root/'manifest.json').write_text(json.dumps(manifest))
   (root/'device-state-final.json').write_text(json.dumps({'phase':'finished','pid':42}))
   for name,data in files.items():
    path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
   (root/'command-receipts.json').write_text(json.dumps([
    {'command':{'operation':'prepare'},'receipt':{'status':'completed'}},
    {'command':{'operation':'begin'},'receipt':{'status':'completed'}}]))
   result=summarize_run(root)
   self.assertTrue(result['complete'],result['reasons'])
   self.assertEqual(result['power']['mean']['status'],'not_requested')
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
 def test_inference_comparison_reports_latency_without_power(self):
  from unittest.mock import patch
  from beolmuri_eval.resource.compare import compare_runs
  with tempfile.TemporaryDirectory() as temporary:
   roots=[Path(temporary)/name for name in ('fresh','cached')]
   for root,mode in zip(roots,('fresh_per_input','cached_full_prompt')):
    root.mkdir()
    (root/'manifest.json').write_text(json.dumps(dict(measurement_mode='inference',config={},model={},
        generation={'conversation_mode':mode},inputs=[{'id':'one'}])))
    (root/'transport.json').write_text(json.dumps(dict(device='synthetic',expected_build_id='same')))
   def summary(run_id,first,prefill,peak):
    return dict(complete=True,run_id=run_id,measurement_environment={'recorder_target_scope':'not_requested'},
      native_inference={'one':{
       'first_response_seconds':{'status':'ok','value':first},
       'generation_elapsed_seconds':{'status':'ok','value':first+1},
       'prefill_tokens_per_second':{'status':'ok','value':prefill}}},
      turns={'one':{'peak':{'status':'ok','value':peak}}},
      power={'mean':{'status':'not_requested','value':None}})
   with patch('beolmuri_eval.resource.compare.summarize_run',side_effect=[
       summary('fresh',2.0,100.0,1000),summary('cached',1.0,200.0,900)]):
    result=compare_runs(*roots,allowed=['generation.conversation_mode'])
   self.assertEqual(result['measurement_mode'],'inference')
   self.assertEqual(result['inference']['first_response_seconds']['delta'],-1.0)
   self.assertEqual(result['inference']['prefill_tokens_per_second']['delta'],100.0)
   self.assertNotIn('power',result)
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
