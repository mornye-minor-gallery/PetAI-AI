import json
from pathlib import Path
import tempfile
import unittest
from beolmuri_eval.evaluation import load_dataset, load_plan, default_config_path, verify_snapshot


class EvaluationInputTests(unittest.TestCase):
    def test_default_config_loads_files_and_all_pairs(self):
        plan = load_plan(default_config_path())
        self.assertEqual(len(plan.cases), 40)
        self.assertEqual(plan.repeats, 3)
        self.assertEqual(plan.variant, 'baseline')
        self.assertEqual(plan.judge['model'], 'gpt-5.6-luna')

    def test_relative_dataset_path_resolves_against_config_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = default_config_path()
            # Absolute references isolate this external config from the checkout.
            text = original.read_text().replace('../datasets/name-identity.jsonl', './custom.jsonl')
            text = text.replace('../judges/', str(original.parent.parent/'judges')+'/')
            text = text.replace('../schemas/', str(original.parent.parent/'schemas')+'/')
            rows = load_dataset(original.parent.parent/'datasets/name-identity.jsonl')[:2]
            rows[0]['user_message'] = '아영아, 같이 이야기하자.'
            (root/'custom.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
            (root/'run.yaml').write_text(text)
            plan = load_plan(root/'run.yaml')
            self.assertEqual(len(plan.cases), 2)
            self.assertEqual(plan.cases[0]['user_message'], rows[0]['user_message'])

    def test_invalid_rows_have_line_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'bad.jsonl'
            path.write_text('{"id":"../escape"}\n')
            with self.assertRaisesRegex(ValueError, 'bad.jsonl:1'):
                load_dataset(path)

    def test_duplicate_ids_and_missing_pair_are_errors(self):
        rows = load_dataset(default_config_path().parent.parent/'datasets/name-identity.jsonl')[:2]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'bad.jsonl'
            for invalid in ([rows[0]], [rows[0], rows[0]], [rows[0], {**rows[1], 'called_name':'아영'}]):
                path.write_text(''.join(json.dumps(r)+'\n' for r in invalid))
                with self.assertRaises(ValueError): load_dataset(path)

    def test_bad_config_does_not_silently_use_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'bad.yaml'
            path.write_text('version: 1\nversion: 2\n')
            with self.assertRaisesRegex(ValueError, 'duplicate'):
                load_plan(path)

    def test_named_variant_is_resolved_from_yaml(self):
        plan = load_plan(default_config_path(), variant='combined', repeats=1, limit_pairs=1)
        self.assertEqual(plan.configuration, {'includePersona':True, 'includeSessionContext':True, 'enforceCharacterName':True, 'memoryClassification':False})
        self.assertEqual(len(plan.cases), 2)
        with self.assertRaisesRegex(ValueError, 'variant'):
            load_plan(default_config_path(), variant='unknown')

    def test_snapshot_preserves_bytes_and_detects_tampering(self):
        plan = load_plan()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metadata = plan.snapshot(root)
            verify_snapshot(root, metadata)
            self.assertEqual((root/'inputs/dataset.jsonl').read_bytes(), plan.files['dataset.jsonl'][1])
            (root/'inputs/judge.md').write_text('changed')
            with self.assertRaisesRegex(ValueError, 'snapshot changed'):
                verify_snapshot(root, metadata)

    def test_external_variant_name_requires_no_python_change(self):
        original = default_config_path()
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'custom.yaml'
            text = original.read_text().replace('name-rule:', 'custom-policy:')
            for directory in ('datasets', 'judges', 'schemas'):
                text = text.replace('../'+directory+'/', str(original.parent.parent/directory)+'/')
            path.write_text(text)
            self.assertTrue(load_plan(path, variant='custom-policy').configuration['enforceCharacterName'])
