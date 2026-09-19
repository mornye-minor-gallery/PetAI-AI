import copy
import unittest
from uuid import uuid4
from beolmuri_eval.resource.config import validate_config
from beolmuri_eval.resource.protocol import command_bytes, decode_command

CONFIG=dict(schema_version=1,target='inference',profile='basic',scenario='paced',
 bundle_id='com.example.resourcebench',fixture='input.jsonl',initial_state='empty.json',
 model_manifest='models.json',generation_config='generation.json',pair_count=1,
 power_window_ms=10000,reply_gap_ms=1000,brightness=0.5,
 required_initial_thermal_state='nominal',ram_sample_period_ms=100,ram_max_gap_ms=300,
 recorder_pre_roll_ms=3000,recorder_post_roll_ms=3000,prepare_timeout_ms=300000,
 turn_timeout_ms=120000,finalize_timeout_ms=300000)

class ProtocolTests(unittest.TestCase):
 def test_valid_config(self): self.assertEqual(validate_config(CONFIG),CONFIG)
 def test_reject_unknown_missing_nonfinite_and_incompatible(self):
  cases=[dict(CONFIG,brightness=float('nan')),dict(CONFIG,pair_count=0),
         dict(CONFIG,typo=1),dict(CONFIG,profile='unity-memory'),dict(CONFIG,ram_max_gap_ms=50)]
  missing=copy.deepcopy(CONFIG);del missing['power_window_ms'];cases.append(missing)
  for config in cases:
   with self.subTest(config=config):
    with self.assertRaises(ValueError): validate_config(config)
 def test_hash_bytes_and_identity_must_match(self):
  command=dict(schema_version=1,run_id=str(uuid4()),operation_id=str(uuid4()),owner_id=str(uuid4()),
               expected_revision=0,operation='prepare',payload={'manifest_sha256':'a'*64})
  name,data=command_bytes(command)
  self.assertEqual(decode_command(name,data),command)
  with self.assertRaises(ValueError): decode_command(name,data+b' ')
  with self.assertRaises(ValueError): decode_command('../'+name,data)
  with self.assertRaises(ValueError): command_bytes(dict(command,schema_version=2))
