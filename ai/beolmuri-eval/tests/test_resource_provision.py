import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from beolmuri_eval.resource.protocol import sha256

class ProvisionTests(unittest.TestCase):
 def exercise(self, corrupt=False):
  from beolmuri_eval.resource.provision import provision_model
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);source=root/'model';source.write_bytes(b'synthetic model')
   config={'bundle_id':'test.resourcebench'};model={'sha256':sha256(source.read_bytes())}
   class Device:
    def __init__(self,*args,**kwargs):pass
    def details(self):return {'hardwareProperties':{'udid':'synthetic-device'},'connectionProperties':{'transportType':'wired'}}
    def copy_to(self,path,destination,**kwargs):self.data=Path(path).read_bytes()
    def copy_from(self,source,destination,**kwargs):Path(destination).write_bytes(b'corrupt' if corrupt else self.data)
   with patch('beolmuri_eval.resource.provision.repository',return_value=root),patch('beolmuri_eval.resource.provision.Device',Device),patch('beolmuri_eval.resource.provision.inputs_from_config',return_value=(config,{},model,source,{},[])):
    if corrupt:
     with self.assertRaisesRegex(ValueError,'SHA-256'):provision_model('config',device_id='synthetic')
    else:
     result=provision_model('config',device_id='synthetic')
     self.assertTrue(result['roundtrip_verified']);self.assertFalse(result['inference_verified'])
     self.assertEqual(result['model_sha256'],model['sha256'])
 def test_roundtrip_confirms_actual_device_bytes(self):self.exercise()
 def test_corrupted_device_bytes_cannot_be_reported_verified(self):self.exercise(corrupt=True)
