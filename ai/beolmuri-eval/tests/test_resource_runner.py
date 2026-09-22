import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from beolmuri_eval.resource.runner import run_one,wait_phase
from beolmuri_eval.resource.summary import summarize_run
from beolmuri_eval.resource.protocol import sha256
from test_resource_protocol import CONFIG
from resource_fixture import app_files,recorder_files,RUN,OWNER

class FakeDevice:
 identifier='synthetic';bundle='com.example.resourcebench'
 def __init__(self):
  self.commands=[];self.files=app_files();self.phase='boot_ready';self.tick=0
 def copy_to(self,path,destination):
  if '/commands/' in destination:
   value=json.loads(Path(path).read_text());operation=value['operation'];self.commands.append(operation)
   self.phase={'prepare':'ready','begin':'finished','cancel':'cancelled'}[operation]
   self.files['receipts/'+value['operation_id']+'.json']=json.dumps({'digest':sha256(Path(path).read_bytes()),'status':'completed'}).encode()
 def copy_from(self,source,destination):
  tail=source.split('/'+RUN+'/')[1]
  Path(destination).write_bytes(self.files[tail])
 def launch(self,run_id):return {'pid':4242}
 def processes(self):return {'runningProcesses':[{'processIdentifier':4242,'executable':'file:///app/Example'}]}
 def state(self,run_id):
  self.tick+=1
  return dict(run_id=RUN,owner_id=OWNER,process_instance_id='one',phase=self.phase,
              pid=4242,revision=self.tick,heartbeat_seq=self.tick,build_id='build',bundle_id=self.bundle)
 def terminate_owned(self,state):return {'termination':'confirmed'}

class FakeRecorder:
 def __init__(self,directory,**kwargs):self.root=Path(directory);self.process=None
 def start(self,**kwargs):pass
 def stop(self,**kwargs):return True
 def export(self):recorder_files(self.root)

class RunnerTests(unittest.TestCase):
 def plan(self):return dict(schema_version=1,run_id=RUN,owner_id=OWNER,role='work',config=dict(CONFIG,power_window_ms=1000))
 def test_full_headless_flow_preserves_and_rederives_evidence(self):
  with tempfile.TemporaryDirectory() as temporary,patch('beolmuri_eval.resource.runner.Recorder',FakeRecorder):
   root=Path(temporary)/RUN;device=FakeDevice()
   result=run_one(root,self.plan(),device,'build',progress=lambda **kw:None)
   self.assertTrue(result['complete'],result)
   self.assertEqual(device.commands,['prepare','begin'])
   one=summarize_run(root);two=summarize_run(root)
   self.assertEqual(one,two)
   self.assertEqual(one['turns']['turn']['extra']['value'],50)
   self.assertEqual(one['native_inference']['turn']['kv_tokens_after']['value'],384)
   self.assertEqual(one['native_inference']['turn']['prefill_tokens']['value'],64)
   self.assertGreater(one['power']['mean']['value'],0)
 def test_recorder_start_failure_cannot_start_inference(self):
  class BrokenRecorder(FakeRecorder):
   def start(self,**kwargs):raise RuntimeError('recorder unavailable')
  with tempfile.TemporaryDirectory() as temporary,patch('beolmuri_eval.resource.runner.Recorder',BrokenRecorder):
   root=Path(temporary)/RUN;device=FakeDevice()
   result=run_one(root,self.plan(),device,'build',progress=lambda **kw:None)
   self.assertFalse(result['complete'])
   self.assertEqual(device.commands,['cancel'])
   self.assertTrue((root/'failure.json').is_file())

 def test_launch_timeout_does_not_prove_the_app_never_started(self):
  class LostDevice(FakeDevice):
   def launch(self,run_id):raise RuntimeError('connection lost after launch request')
   def state(self,run_id):raise RuntimeError('unreachable')
  with tempfile.TemporaryDirectory() as temporary,patch('beolmuri_eval.resource.runner.Recorder',FakeRecorder):
   result=run_one(Path(temporary)/RUN,self.plan(),LostDevice(),'build',progress=lambda **kw:None)
   self.assertFalse(result['termination_confirmed'])
 def test_recorder_still_saving_keeps_device_ownership(self):
  class HungRecorder(FakeRecorder):
   def start(self,**kwargs):
    class Process:
     def poll(self):return None
    self.process=Process()
   def stop(self,**kwargs):raise TimeoutError('still saving')
  with tempfile.TemporaryDirectory() as temporary,patch('beolmuri_eval.resource.runner.Recorder',HungRecorder):
   result=run_one(Path(temporary)/RUN,self.plan(),FakeDevice(),'build',progress=lambda **kw:None)
   self.assertFalse(result['termination_confirmed'])

 def test_missing_live_pid_prevents_recorder_start(self):
  class MissingDevice(FakeDevice):
   def processes(self):return {'runningProcesses':[]}
  with tempfile.TemporaryDirectory() as temporary,patch('beolmuri_eval.resource.runner.Recorder',FakeRecorder):
   result=run_one(Path(temporary)/RUN,self.plan(),MissingDevice(),'build',progress=lambda **kw:None)
   self.assertFalse(result['complete'])
   self.assertIn('process inventory',result['reason'])

 def test_wait_phase_reports_a_disappeared_app_process(self):
  class MissingProcessDevice:
   def state(self,run_id):
    return dict(run_id=RUN,owner_id=OWNER,process_instance_id='one',phase='preparing',
                pid=4242,revision=2,heartbeat_seq=2,build_id='build',bundle_id='com.example.resourcebench')
   def processes(self):return {'runningProcesses':[]}
  class StaleObservation:
   def observe(self,state,now):return {'observation':'unknown','last_device_state':state}
  with tempfile.TemporaryDirectory() as temporary:
   with self.assertRaisesRegex(RuntimeError,'app process exited while awaiting ready'):
    wait_phase(MissingProcessDevice(),Path(temporary),self.plan(),{'ready'},timeout=1,
               observer=StaleObservation(),progress=lambda **kw:None)

 def test_wait_phase_reports_launch_pid_exit_before_first_state(self):
  class MissingStateDevice:
   def state(self,run_id):raise RuntimeError('state file unavailable')
   def processes(self):return {'runningProcesses':[]}
  with tempfile.TemporaryDirectory() as temporary:
   with self.assertRaisesRegex(RuntimeError,'app process exited while awaiting boot_ready'):
    wait_phase(MissingStateDevice(),Path(temporary),self.plan(),{'boot_ready'},timeout=1,
               observer=object(),progress=lambda **kw:None,expected_pid=4242)
