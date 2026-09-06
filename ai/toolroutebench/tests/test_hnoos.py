from __future__ import annotations

import unittest
import hashlib

from toolroutebench.common import ToolRouteBenchError
from toolroutebench.hnoos import parse_hnoos_records, select_petai_relevant_hnoos


class HardNegativeOOSDatasetTests(unittest.TestCase):
    def test_parser_normalizes_and_deduplicates_records(self) -> None:
        rows = parse_hnoos_records(
            [
                ["does a timer  measure minutes", "timer"],
                ["does a timer measure minutes", "timer"],
            ],
            source_dataset="clinc150",
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["utterance"], "does a timer measure minutes")

    def test_selection_keeps_relevant_no_call_and_excludes_petai_call(self) -> None:
        rows = parse_hnoos_records(
            [
                ["does a timer measure minutes", "timer"],
                ["synthetic reminder request 2", "alarm_set"],
                ["how do i transfer money", "card_payment"],
            ],
            source_dataset="clinc150",
        )
        selected = select_petai_relevant_hnoos(
            rows,
            included_target_intents={"timer", "alarm_set"},
            excluded_petai_call_sha256={hashlib.sha256(b"synthetic reminder request 2").hexdigest()},
        )
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0]["utterance"], "does a timer measure minutes")
        self.assertFalse(selected[0]["call"])
        self.assertEqual(selected[0]["split"], "train")

    def test_selection_rejects_stale_exclusion_contract(self) -> None:
        rows = parse_hnoos_records(
            [["does a timer measure minutes", "timer"]],
            source_dataset="clinc150",
        )
        with self.assertRaises(ToolRouteBenchError):
            select_petai_relevant_hnoos(
                rows,
                included_target_intents={"timer"},
                excluded_petai_call_sha256={hashlib.sha256(b"missing row").hexdigest()},
            )


if __name__ == "__main__":
    unittest.main()
