import unittest
import json
from pathlib import Path
from beolmuri_eval.resource.config import validate_document


class CachedManifestTests(unittest.TestCase):
 def test_cached_full_prompt_manifest(self):
    root = Path(__file__).resolve().parents[3]
    manifest = json.loads((root / 'contracts/resource-benchmark/examples/manifest.json').read_text())
    manifest['generation']['conversation_mode'] = 'cached_full_prompt'
    assert validate_document('manifest', manifest) == manifest

class CacheMetricsTests(unittest.TestCase):
 def test_overlap_is_not_reported_as_native_kv_size(self):
    from beolmuri_eval.resource.summary import _native_inference_metrics
    payload = dict(turn_id='one', generation_id='gen', input_tokens=120,
                   matching_input_prefix_tokens=100, first_response_seconds=.2,
                   generation_elapsed_seconds=1, prefill_tokens=120,
                   prefill_tokens_per_second=1000, decode_tokens=5, decode_tokens_per_second=10)
    row = _native_inference_metrics([dict(kind='native_inference_metrics',payload=payload)], cached=True)['one']
    self.assertEqual(row['kv_tokens_after']['status'], 'unsupported')
    self.assertIsNone(row['kv_tokens_after']['value'])
    self.assertEqual(row['matching_input_prefix_tokens']['value'], 100)
    self.assertIn('not_native_hits', row['matching_input_prefix_tokens']['source'])
 def test_missing_cache_metrics_remain_invalid(self):
    from beolmuri_eval.resource.summary import _native_inference_metrics
    row = _native_inference_metrics([dict(kind='native_inference_metrics',payload={'turn_id':'one'})], cached=True)['one']
    self.assertEqual(row['input_tokens']['status'], 'invalid')
    self.assertEqual(row['first_response_seconds']['status'], 'invalid')
