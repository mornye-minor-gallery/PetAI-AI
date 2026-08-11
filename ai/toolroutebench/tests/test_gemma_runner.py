from __future__ import annotations

import unittest

from toolroutebench.common import ToolRouteBenchError
from toolroutebench.gemma_runner import (
    LiteRTLMOpenAIClient,
    parse_prompt_route,
)


TOOLS = [
    "get_step_count",
    "create_alarm",
    "list_alarms",
    "create_timer",
    "schedule_local_notification",
    "get_calendar_events",
    "create_calendar_event",
]


class GemmaRunnerTests(unittest.TestCase):
    def test_exact_tool_and_normal_labels_are_strict(self) -> None:
        self.assertEqual(
            parse_prompt_route("create_timer\n", TOOLS),
            (["create_timer"], "strict"),
        )
        self.assertEqual(parse_prompt_route("normal", TOOLS), ([], "strict"))

    def test_extra_text_fails_closed(self) -> None:
        self.assertEqual(
            parse_prompt_route("판정: get_step_count", TOOLS),
            ([], "fallback"),
        )

    def test_missing_or_multiple_labels_fail_closed(self) -> None:
        self.assertEqual(parse_prompt_route("도구 없음", TOOLS), ([], "fallback"))
        self.assertEqual(
            parse_prompt_route("create_alarm 또는 create_timer", TOOLS),
            ([], "fallback"),
        )
        self.assertEqual(
            parse_prompt_route("NORMAL 대신 create_alarm", TOOLS),
            ([], "fallback"),
        )

    def test_http_client_rejects_non_loopback_server(self) -> None:
        with self.assertRaisesRegex(ToolRouteBenchError, "loopback"):
            LiteRTLMOpenAIClient(
                base_url="https://example.com",
                timeout_seconds=1,
            )

    def test_http_client_rejects_loopback_url_with_path(self) -> None:
        with self.assertRaisesRegex(ToolRouteBenchError, "path"):
            LiteRTLMOpenAIClient(
                base_url="http://127.0.0.1:9379/v1",
                timeout_seconds=1,
            )


if __name__ == "__main__":
    unittest.main()
