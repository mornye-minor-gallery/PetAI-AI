from __future__ import annotations

import unittest

from toolroutebench.regex_baseline import (
    PythonKoreanNativeToolRouter,
    validate_regex_source,
)


class RegexBaselineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.router = PythonKoreanNativeToolRouter()

    def test_swift_source_sha_is_locked(self) -> None:
        self.assertEqual(
            validate_regex_source()["sha256"],
            "3ba84d2685d414ad25fe889ff4e8c94a268cec0b28d4f37f603df8f586aef736",
        )

    def test_selects_every_supported_tool_like_swift_fixture(self) -> None:
        cases = {
            "오늘 몇 걸음 걸었어?": ["get_step_count"],
            "내일 아침 7시에 운동 알람 맞춰 줘": ["create_alarm"],
            "내 알람 목록 보여 줘": ["list_alarms"],
            "10분 타이머 시작해 줘": ["create_timer"],
            "오후 3시에 물 마시라고 알려 줘": ["schedule_local_notification"],
            "내일 일정 알려 줘": ["get_calendar_events"],
            "내일 3시에 멘토링 일정 잡아 줘": ["create_calendar_event"],
        }
        for utterance, expected in cases.items():
            self.assertEqual(self.router.route(utterance), expected)

    def test_relative_duration_alarm_override_matches_swift_fixture(self) -> None:
        for utterance in (
            "10초 뒤 알람 맞춰 줘",
            "10분 후 알람 설정해 줘",
            "한 시간 뒤에 깨워 줘",
            "ㄷ10초뒤 알람 맞춰줘",
        ):
            self.assertEqual(self.router.route(utterance), ["create_timer"])

    def test_statements_stay_normal_like_swift_fixture(self) -> None:
        for utterance in (
            "오늘 만 보 걸었어",
            "알람 소리 너무 싫어",
            "내일 약속이 있어",
            "요즘 타이머를 자주 써",
            "안녕, 오늘 기분 어때?",
        ):
            self.assertEqual(self.router.route(utterance), [])

    def test_conflict_preserves_native_tool_order(self) -> None:
        self.assertEqual(
            self.router.route("내일 일정을 보여 주고 7시 알람도 맞춰 줘"),
            ["create_alarm", "get_calendar_events"],
        )


if __name__ == "__main__":
    unittest.main()
