import json
from pathlib import Path
import tempfile
import time
import sys
import unittest
from uuid import uuid4
from beolmuri_eval.resource.observation import Observation
from beolmuri_eval.resource.collection import collect_files
from beolmuri_eval.resource.protocol import sha256
from beolmuri_eval.resource.recorder import StartedSignal, Recorder

class HostTests(unittest.TestCase):
 def test_copying_stale_heartbeat_does_not_prove_liveness(self):
  view=Observation(run_id='run',owner_id='owner',stale_after=20)
  s=dict(run_id='run',owner_id='owner',process_instance_id='proc',heartbeat_seq=1,phase='running')
  self.assertEqual(view.observe(s,now=0)['observation'],'known')
  self.assertEqual(view.observe(s,now=21)['observation'],'unknown')
  self.assertEqual(view.observe(dict(s,heartbeat_seq=2),now=22)['observation'],'known')
  with self.assertRaises(ValueError): view.observe(dict(s,process_instance_id='new'),now=23)
 @unittest.skipUnless(sys.platform == "darwin", "Darwin notifications require macOS")
 def test_darwin_notification_is_not_pretended_by_elapsed_time(self):
  with StartedSignal('org.petai.test.'+str(uuid4())) as signal:
   self.assertFalse(signal.received())
   signal.post_for_test()
   deadline=time.monotonic()+1
   received=False
   while time.monotonic()<deadline and not received:
    received=signal.received()
    if not received: time.sleep(0.01)
   self.assertTrue(received)
 def test_collection_verifies_hash_and_never_overwrites_raw(self):
  with tempfile.TemporaryDirectory() as temp:
   root=Path(temp)
   source=b'{"sample":1}\n'
   index=dict(files=[dict(path='raw/ram.jsonl',kind='ram',bytes=len(source),sha256=sha256(source),complete=True)])
   def fetch(remote,path): path.write_bytes(source)
   collect_files(root,index,fetch)
   self.assertEqual((root/'raw/ram.jsonl').read_bytes(),source)
   bad=dict(files=[dict(index['files'][0],sha256='0'*64)])
   with self.assertRaises(ValueError): collect_files(root,bad,fetch)
   self.assertEqual((root/'raw/ram.jsonl').read_bytes(),source)
   escape=dict(files=[dict(index['files'][0],path='../outside')])
   with self.assertRaises(ValueError): collect_files(root,escape,fetch)

class RecorderLifecycleTests(unittest.TestCase):
 def test_stop_is_idempotent_and_preserves_original_stop_evidence(self):
  class Process:
   pid=123;stdin=None;returncode=None;signals=0
   def poll(self):return self.returncode
   def send_signal(self,value):self.signals+=1;self.returncode=0
  with tempfile.TemporaryDirectory() as temp:
   recorder=Recorder(Path(temp));recorder.trace.mkdir();recorder.process=Process()
   self.assertTrue(recorder.stop(timeout=1))
   self.assertTrue(recorder.stop(timeout=1))
   self.assertEqual(recorder.process.signals,1)
   self.assertTrue(json.loads((Path(temp)/'result.json').read_text())['stopped_by_host'])
   self.assertEqual(json.loads((Path(temp)/'result.json').read_text())['target_scope'],'all_processes')

class DeviceArgumentTests(unittest.TestCase):
 def test_timeout_uses_integer_seconds_without_shortening_deadline(self):
  from unittest.mock import patch
  from beolmuri_eval.resource.device import Device
  with tempfile.TemporaryDirectory() as temp:
   device=Device('synthetic','test.resourcebench',temp)
   def invoke(argv,*args,**kwargs):
    self.assertEqual(argv[argv.index('--timeout')+1],'301')
    Path(argv[argv.index('--json-output')+1]).write_text(json.dumps({'info':{'outcome':'success'},'result':{}}))
   with patch('beolmuri_eval.resource.device.run_tool',side_effect=invoke):device.call(['device','info','details'],timeout=300.1)
