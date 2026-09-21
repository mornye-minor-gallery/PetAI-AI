from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
from beolmuri_eval.runner import create_run
from beolmuri_eval.cli import parser

class OutputTests(unittest.TestCase):
    def test_explicit_output_root_stores_run_outside_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = SimpleNamespace(config=None, variant=None, repeats=1, limit_pairs=1,
                timeout=None, model=None, litert_python=None, codex='codex', output_root=tmp)
            detail = {'deployment_model':{},'litert_python':'python','litert_native_library':{'version':'test','backend':'gpu'},'codex_cli':'test'}
            env = {'ready':True,'checks':[{'name':k,'status':'pass','detail':v} for k,v in detail.items()], 'runtime_parity':'test'}
            with patch('beolmuri_eval.runner.build'), patch('beolmuri_eval.runner.validate_swift'), patch('beolmuri_eval.runner.inspect_environment',return_value=env), patch('beolmuri_eval.runner.source_sha',return_value='test'), patch('beolmuri_eval.runner.execute',return_value=('commit','')):
                directory = create_run(args)
            self.assertEqual(directory.parent,Path(tmp).resolve())
            self.assertTrue((directory/'manifest.json').exists())
            self.assertTrue((directory/'inputs/dataset.jsonl').exists())

    def test_cli_accepts_output_root(self):
        args = parser().parse_args(['run','--output-root','external-runs'])
        self.assertEqual(args.output_root,'external-runs')
