from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from hybrid_memory_harness import (  # noqa: E402
    DecisionSource,
    HeaderSyntax,
    HybridMemoryHarness,
    MemoryDecision,
    MemoryDecisionParser,
    MemoryHeaderFormat,
    MemoryHeaderGate,
    contains_control_leak,
)


class StubFallback:
    def __init__(self, decision: MemoryDecision) -> None:
        self.decision = decision
        self.calls = 0

    def classify(
        self,
        *,
        record_id: str,
        utterance: str,
    ) -> MemoryDecision:
        self.calls += 1
        return self.decision


class MemoryHeaderGateTests(unittest.TestCase):
    def decode(
        self,
        chunks: list[str],
        *,
        parser: MemoryDecisionParser | None = None,
    ):
        gate = MemoryHeaderGate(parser or MemoryDecisionParser())
        visible: list[str] = []
        for chunk in chunks:
            visible.extend(gate.consume(chunk))
        result = gate.finish()
        self.assertEqual("".join(visible), result.visible_text)
        return result

    def test_canonical_header_survives_arbitrary_chunk_boundaries(self) -> None:
        variants = [
            ["save(P)\n딸기가 좋구나."],
            ["sa", "ve", "(", "P", ")\n", "딸기가 ", "좋구나."],
            ["save(P)", "\n딸기가 좋구나."],
        ]
        for chunks in variants:
            with self.subTest(chunks=chunks):
                result = self.decode(chunks)
                self.assertEqual(result.decision, MemoryDecision.PREFERENCE)
                self.assertEqual(result.syntax, HeaderSyntax.CANONICAL)
                self.assertEqual(result.visible_text, "딸기가 좋구나.")

    def test_recovered_slash_header_is_hidden(self) -> None:
        result = self.decode(["E / 어제 다녀왔구나."])

        self.assertEqual(result.decision, MemoryDecision.EVENT)
        self.assertEqual(result.syntax, HeaderSyntax.RECOVERED)
        self.assertEqual(result.visible_text, "어제 다녀왔구나.")

    def test_malformed_control_line_is_removed(self) -> None:
        result = self.decode(["N/P\n대화는 계속한다."])

        self.assertIsNone(result.decision)
        self.assertEqual(result.syntax, HeaderSyntax.MALFORMED)
        self.assertEqual(result.visible_text, "대화는 계속한다.")

    def test_plain_chat_is_preserved(self) -> None:
        result = self.decode(["그랬구나. 재미있었겠다."])

        self.assertIsNone(result.decision)
        self.assertEqual(result.syntax, HeaderSyntax.ABSENT)
        self.assertEqual(
            result.visible_text,
            "그랬구나. 재미있었겠다.",
        )

    def test_axis_header_maps_all_four_combinations(self) -> None:
        parser = MemoryDecisionParser(
            header_format=MemoryHeaderFormat.AXES
        )
        cases = {
            "P=0 E=0": MemoryDecision.NONE,
            "P=1 E=0": MemoryDecision.PREFERENCE,
            "P=0 E=1": MemoryDecision.EVENT,
            "P=1 E=1": MemoryDecision.BOTH,
        }
        for header, expected in cases.items():
            with self.subTest(header=header):
                result = self.decode(
                    [header[:2], header[2:5], header[5:], "\n답변"],
                    parser=parser,
                )
                self.assertEqual(result.decision, expected)
                self.assertEqual(result.syntax, HeaderSyntax.CANONICAL)
                self.assertEqual(result.visible_text, "답변")

    def test_additional_formats_map_all_four_combinations(self) -> None:
        formats = {
            MemoryHeaderFormat.SET: {
                "save(N)": MemoryDecision.NONE,
                "save(P)": MemoryDecision.PREFERENCE,
                "save(E)": MemoryDecision.EVENT,
                "save(P,E)": MemoryDecision.BOTH,
            },
            MemoryHeaderFormat.FULL_AXES: {
                "Preference=0 Event=0": MemoryDecision.NONE,
                "Preference=1 Event=0": MemoryDecision.PREFERENCE,
                "Preference=0 Event=1": MemoryDecision.EVENT,
                "Preference=1 Event=1": MemoryDecision.BOTH,
            },
            MemoryHeaderFormat.WRAPPED_AXES: {
                "save(P=0,E=0)": MemoryDecision.NONE,
                "save(P=1,E=0)": MemoryDecision.PREFERENCE,
                "save(P=0,E=1)": MemoryDecision.EVENT,
                "save(P=1,E=1)": MemoryDecision.BOTH,
            },
        }
        for header_format, cases in formats.items():
            parser = MemoryDecisionParser(
                header_format=header_format
            )
            for header, expected in cases.items():
                with self.subTest(
                    header_format=header_format,
                    header=header,
                ):
                    result = self.decode(
                        [
                            header[:2],
                            header[2:7],
                            header[7:],
                            "\n답변",
                        ],
                        parser=parser,
                    )
                    self.assertEqual(result.decision, expected)
                    self.assertEqual(
                        result.syntax,
                        HeaderSyntax.CANONICAL,
                    )
                    self.assertEqual(result.visible_text, "답변")

    def test_malformed_axis_header_is_hidden(self) -> None:
        parser = MemoryDecisionParser(
            header_format=MemoryHeaderFormat.AXES
        )
        result = self.decode(
            ["P=1 E=2\n대화는 계속한다."],
            parser=parser,
        )

        self.assertIsNone(result.decision)
        self.assertEqual(result.syntax, HeaderSyntax.MALFORMED)
        self.assertEqual(result.visible_text, "대화는 계속한다.")

    def test_axis_control_header_is_detected_as_leak(self) -> None:
        self.assertTrue(contains_control_leak("P=1 E=0\n답변"))
        self.assertTrue(
            contains_control_leak(
                "Preference=1 Event=0\n답변"
            )
        )

    def test_additional_malformed_headers_are_hidden(self) -> None:
        cases = {
            MemoryHeaderFormat.SET: "save(E,P)\n답변",
            MemoryHeaderFormat.FULL_AXES: (
                "Preference=1 Event=2\n답변"
            ),
            MemoryHeaderFormat.WRAPPED_AXES: (
                "save(P=1,E=2)\n답변"
            ),
        }
        for header_format, output in cases.items():
            with self.subTest(header_format=header_format):
                result = self.decode(
                    [output],
                    parser=MemoryDecisionParser(
                        header_format=header_format
                    ),
                )
                self.assertIsNone(result.decision)
                self.assertEqual(
                    result.syntax,
                    HeaderSyntax.MALFORMED,
                )
                self.assertEqual(result.visible_text, "답변")


class HybridMemoryHarnessTests(unittest.TestCase):
    def test_label_only_retries_body_without_classifier(self) -> None:
        fallback = StubFallback(MemoryDecision.EVENT)
        harness = HybridMemoryHarness()

        outcome = harness.run(
            request_id="request-one",
            record_id="record-one",
            user_message="나는 딸기가 좋아.",
            primary_generation=lambda: iter(["P"]),
            retry_generation=lambda _: iter(
                ["딸기를 정말 좋아하는구나."]
            ),
            fallback_classifier=fallback,
        )

        self.assertEqual(outcome.decision, MemoryDecision.PREFERENCE)
        self.assertEqual(outcome.decision_source, DecisionSource.PRIMARY)
        self.assertTrue(outcome.retry_attempted)
        self.assertTrue(outcome.retry_succeeded)
        self.assertEqual(fallback.calls, 0)
        self.assertTrue(outcome.should_commit)

    def test_plain_chat_uses_mlp_fallback(self) -> None:
        fallback = StubFallback(MemoryDecision.BOTH)
        harness = HybridMemoryHarness()

        outcome = harness.run(
            request_id="request-two",
            record_id="record-two",
            user_message="어제 먹었는데 완전 내 취향이야.",
            primary_generation=lambda: iter(
                ["그 음식이 정말 마음에 들었구나."]
            ),
            retry_generation=lambda _: iter(()),
            fallback_classifier=fallback,
        )

        self.assertEqual(outcome.decision, MemoryDecision.BOTH)
        self.assertEqual(outcome.decision_source, DecisionSource.FALLBACK)
        self.assertFalse(outcome.retry_attempted)
        self.assertEqual(fallback.calls, 1)
        self.assertTrue(outcome.should_commit)

    def test_failed_fallback_keeps_chat_and_does_not_save(self) -> None:
        class FailingFallback:
            def classify(self, *, record_id: str, utterance: str):
                raise RuntimeError("classifier unavailable")

        harness = HybridMemoryHarness()
        outcome = harness.run(
            request_id="request-three",
            record_id="record-three",
            user_message="사용자 문장",
            primary_generation=lambda: iter(["자연스러운 답변"]),
            retry_generation=lambda _: iter(()),
            fallback_classifier=FailingFallback(),
        )

        self.assertEqual(outcome.visible_text, "자연스러운 답변")
        self.assertEqual(outcome.decision, MemoryDecision.NONE)
        self.assertEqual(
            outcome.decision_source,
            DecisionSource.UNRESOLVED,
        )
        self.assertFalse(outcome.should_commit)
        self.assertTrue(outcome.errors)


if __name__ == "__main__":
    unittest.main()
