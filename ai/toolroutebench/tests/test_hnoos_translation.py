from __future__ import annotations

import unittest

from toolroutebench.common import ToolRouteBenchError
from toolroutebench.hnoos_translation import parse_korean_translation


class HardNegativeOOSTranslationTests(unittest.TestCase):
    def test_parses_raw_and_fenced_strict_json(self) -> None:
        self.assertEqual(
            parse_korean_translation('{"ko":"타이머는 분 단위인가요?"}'),
            "타이머는 분 단위인가요?",
        )
        self.assertEqual(
            parse_korean_translation(
                '```json\n{"ko":"알람 없이 상쾌하게 깨는 방법이 뭐야?"}\n```'
            ),
            "알람 없이 상쾌하게 깨는 방법이 뭐야?",
        )

    def test_rejects_explanation_or_non_korean_output(self) -> None:
        for raw in (
            '번역입니다: {"ko":"타이머가 뭐야?"}',
            '{"ko":"what is a timer?"}',
            '{"ko":"타이머가 뭐야?","note":"extra"}',
        ):
            with self.subTest(raw=raw):
                with self.assertRaises(ToolRouteBenchError):
                    parse_korean_translation(raw)


if __name__ == "__main__":
    unittest.main()
