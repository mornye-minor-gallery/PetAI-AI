import unittest
from decimal import Decimal
from pathlib import Path
from beolmuri_eval.resource.power import read_power, analyze_power, PowerSample
from beolmuri_eval.resource.memory import analyze_turn

FIXTURE = Path(__file__).parent / 'fixtures/resource/power.xml'

class PowerTests(unittest.TestCase):
    def test_actual_export_shape_and_reference(self):
        rows = read_power(FIXTURE.read_bytes())
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0].start_ns, 639868125)
        self.assertEqual(rows[0].rate, Decimal('10.851259819'))

    def test_overlap_weighting_not_arithmetic_mean(self):
        rows = [PowerSample(0, 1_000_000_000, Decimal(2)),
                PowerSample(1_000_000_000, 3_000_000_000, Decimal(8))]
        result = analyze_power(rows, 500_000_000, 2_000_000_000,
                               end_reason='Time limit reached', charging='unplugged')
        self.assertEqual(result['mean']['status'], 'ok')
        self.assertAlmostEqual(result['mean']['value'], 6)
        self.assertAlmostEqual(result['consumption']['value'], 9 / 3600)

    def test_exit_zero_cannot_rescue_disconnect(self):
        result = analyze_power([PowerSample(0, 10, Decimal(2))], 0, 10,
                               end_reason='Device disconnected', charging='unplugged')
        self.assertEqual(result['mean']['status'], 'invalid')
        self.assertIsNone(result['mean']['value'])

    def test_gap_charging_empty_overlap_and_unknown_are_invalid(self):
        cases = [([], 'unplugged'),
                 ([PowerSample(0, 10_000, Decimal(2))], 'unknown'),
                 ([PowerSample(0, 10_000, Decimal(0))], 'charging'),
                 ([PowerSample(0, 2000, Decimal(2)), PowerSample(4000, 6000, Decimal(2))], 'unplugged'),
                 ([PowerSample(0, 10_000, Decimal(2)), PowerSample(0, 10_000, Decimal(2))], 'unplugged')]
        for rows, charging in cases:
            with self.subTest(rows=rows, charging=charging):
                r = analyze_power(rows, 0, 10_000, end_reason='Time limit reached', charging=charging)
                self.assertNotEqual(r['mean']['status'], 'ok')
                self.assertIsNone(r['mean']['value'])

    def test_small_numeric_gap_is_reported_not_filled(self):
        rows = [PowerSample(0, 1_000_000_000, Decimal(2)),
                PowerSample(1_000_000_042, 999_999_958, Decimal(2))]
        r = analyze_power(rows, 0, 2_000_000_000, end_reason='Time limit reached', charging='unplugged')
        self.assertEqual(r['mean']['status'], 'ok')
        self.assertEqual(r['coverage_ns'], 1_999_999_958)
        self.assertEqual(r['gap_ns'], 42)

    def test_bad_reference_and_nonfinite_fail(self):
        original = FIXTURE.read_bytes()
        for data in (original.replace(b'ref="4"', b'ref="99999"'),
                     original.replace(b'10.851259819', b'NaN'),
                     original.replace(b'percent-per-hour', b'watts')):
            with self.subTest(data=data[:20]):
                with self.assertRaises(ValueError): read_power(data)

class MemoryTests(unittest.TestCase):
    def rows(self):
        return [dict(seq=i, monotonic_ns=str(i*100_000_000), bytes=v, status='ok',
                     boundary=b, turn_id='turn-1')
                for i,(v,b) in enumerate([(100,'turn_start'),(180,None),(130,'turn_end')])]

    def test_observed_peak_and_delta(self):
        r=analyze_turn(self.rows(), 'turn-1', max_gap_ns=300_000_000)
        self.assertEqual(r['peak']['value'],180)
        self.assertEqual(r['extra']['value'],80)
        self.assertEqual(r['after']['value'],130)

    def test_missing_boundary_gap_failed_sample_are_invalid(self):
        rows=self.rows()
        variants=[rows[:-1], [rows[0],dict(rows[1],status='error',bytes=None),rows[2]],
                  [rows[0],dict(rows[1],monotonic_ns='900000000'),dict(rows[2],monotonic_ns='1000000000')]]
        for v in variants:
            with self.subTest(v=v):
                r=analyze_turn(v,'turn-1',max_gap_ns=300_000_000)
                self.assertEqual(r['peak']['status'],'invalid')
                self.assertIsNone(r['extra']['value'])
