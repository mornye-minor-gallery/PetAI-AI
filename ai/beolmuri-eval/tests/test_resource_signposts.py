from pathlib import Path
import unittest
from beolmuri_eval.resource.signposts import window_from_trace
FIXTURE=Path(__file__).parent/'fixtures/resource/signposts.xml'
RUN='00000000-0000-0000-0000-000000000001'
class SignpostTests(unittest.TestCase):
 def test_real_typed_export_matches_both_endpoints_and_pid(self):
  self.assertEqual(window_from_trace(FIXTURE.read_bytes(),run_id=RUN,pid=4242),(1774535125,3783283083))
 def test_other_run_or_process_is_not_a_measurement_window(self):
  with self.assertRaises(ValueError):window_from_trace(FIXTURE.read_bytes(),run_id=RUN,pid=1)
  with self.assertRaises(ValueError):window_from_trace(FIXTURE.read_bytes(),run_id='other',pid=4242)
  data=FIXTURE.read_bytes().replace(b'ref="13"',b'ref="999"')
  with self.assertRaises(ValueError):window_from_trace(data,run_id=RUN,pid=4242)
