import contextlib
import io
import json
import unittest
from unittest.mock import patch
from beolmuri_eval.cli import main
from beolmuri_eval.doctor_view import render_doctor

REPORT = {
    'ready': True,
    'checks': [{'name': 'deployment_model', 'status': 'pass',
                'detail': {'sha256': 'a'*64, 'path': '/private/model', 'quantization': 'mobile QAT'}},
               {'name': 'codex_cli', 'status': 'pass', 'detail': 'codex-cli 0.153.4'}],
    'judge': {'access': 'UNVERIFIED: use --probe', 'model': 'gpt-5.6-sol', 'reasoning_effort': 'medium'},
    'scope': 'single-turn-fixed-general-empty-memory',
    'runtime_parity': 'Mac LiteRT-LM 0.13.1; mobile fork 0.14.0 is not the same runtime',
}


class DoctorViewTests(unittest.TestCase):
    def test_judge_probe_displays_the_configured_model(self):
        for model in ('gpt-5.6-sol', 'gpt-5.6-luna'):
            report = {**REPORT, 'checks': [
                {'name': 'codex_judge', 'status': 'pass', 'detail': {
                    'model': model, 'reasoning_effort': 'medium',
                    'judgment': {'label': 'identity_maintained'}}}]}
            text = render_doctor(report)
            self.assertIn('Codex 실제 채점', text)
            self.assertIn(f'{model} · medium · 판정 검증 완료', text)

    def test_human_view_distinguishes_pass_from_unverified_without_raw_payload(self):
        text = render_doctor(REPORT, color=True)
        self.assertIn('\x1b[32m', text)
        self.assertIn('✓', text)
        self.assertIn('--probe', text)
        self.assertNotIn('/private/model', text)
        self.assertNotIn('a'*64, text)

    def test_failure_remains_visible_without_color(self):
        report = {**REPORT, 'ready': False, 'checks': [
            {'name': 'swift_worker', 'status': 'fail', 'detail': 'Swift worker missing; run beolmuri-eval build'}]}
        text = render_doctor(report, color=False)
        self.assertIn('✗', text)
        self.assertIn('beolmuri-eval build', text)
        self.assertNotIn('\x1b[', text)

    def test_json_flag_preserves_machine_readable_contract(self):
        with patch('sys.argv', ['beolmuri-eval', 'doctor', '--json']), \
             patch('beolmuri_eval.cli.inspect_environment', return_value=REPORT), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main(), 0)
        self.assertEqual(json.loads(output.getvalue()), REPORT)
