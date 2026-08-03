from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "evaluate_kv_extraction.py"
SPEC = importlib.util.spec_from_file_location("evaluate_kv_extraction", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ParsePredictionTests(unittest.TestCase):
    def test_parses_canonical_object(self) -> None:
        parsed = MODULE.parse_prediction(
            '{"preference.food":"떡볶이"}'
        )
        self.assertEqual(parsed.status, "canonical_object")
        self.assertEqual(
            parsed.value,
            {"key": "preference.food", "value": "떡볶이"},
        )

    def test_parses_canonical_null(self) -> None:
        parsed = MODULE.parse_prediction("null\n")
        self.assertEqual(parsed.status, "canonical_null")
        self.assertIsNone(parsed.value)

    def test_rejects_unknown_key(self) -> None:
        parsed = MODULE.parse_prediction(
            '{"profile.age":"20"}'
        )
        self.assertEqual(parsed.status, "unknown_key")
        self.assertIsNone(parsed.value)

    def test_rejects_extra_fields(self) -> None:
        parsed = MODULE.parse_prediction(
            '{"profile.school":"아주대학교","profile.major":"소프트웨어학과"}'
        )
        self.assertEqual(parsed.status, "invalid_fields")

    def test_rejects_markdown_fence(self) -> None:
        parsed = MODULE.parse_prediction(
            '```json\n{"profile.school":"아주대학교"}\n```'
        )
        self.assertEqual(parsed.status, "invalid_json")

    def test_rejects_empty_value(self) -> None:
        parsed = MODULE.parse_prediction(
            '{"profile.school":"   "}'
        )
        self.assertEqual(parsed.status, "invalid_value")


class DatasetTests(unittest.TestCase):
    def test_frozen_smoke_contract(self) -> None:
        rows = MODULE.load_dataset(
            Path(__file__).parents[1] / "data" / "smoke_v0.jsonl"
        )
        self.assertEqual(len(rows), 24)
        self.assertEqual(sum(row["expected"] is None for row in rows), 8)


if __name__ == "__main__":
    unittest.main()
