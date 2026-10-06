import json
from pathlib import Path
import tempfile
import unittest

from beolmuri_eval.resource.dialogue_fixture import compose_dialogue_fixture
from beolmuri_eval.resource.protocol import sha256


class FakeWorker:
    def __init__(self):
        self.calls = []

    def call(self, operation, **payload):
        self.calls.append((operation, payload))
        history = payload["history"]
        return {
            "model_input": {"messages": [
                {"role": "system", "text": "constant production prefix"},
                *([{"role": "user", "text": "\n".join(row['user'] + row['assistant'] for row in history)}] if history else []),
                {"role": "system", "text": "request context"},
                {"role": "user", "text": payload['userMessage']},
            ]},
            "system_prompt": "constant production prefix",
            "user_prompt": "\n".join([row["user"] + row["assistant"] for row in history]
                                      + [payload["userMessage"]]),
            "prompt_trace": {
                "sections": [
                    {"placement": "system", "source": "persona"},
                    {"placement": "user", "source": "currentMessage"},
                ]
            },
        }


class DialogueFixtureTests(unittest.TestCase):
    def test_canonical_content_is_composed_by_swift_with_retrieval_explicitly_disabled(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            content = root / "dialogue-content.json"
            content.write_text(json.dumps({
                "id": "elena", "name": "엘레나", "persona": "정본", "retrieval": {"enabled": True}
            }, ensure_ascii=False))
            turns = root / "turns.json"
            turns.write_text(json.dumps([
                {"id": "one", "user_message": "안녕", "history": []},
                {"id": "two", "user_message": "오늘 뭐 할까?",
                 "history": [{"user": "안녕", "assistant": "반가워."}]},
            ], ensure_ascii=False))
            worker = FakeWorker()
            rows, provenance = compose_dialogue_fixture(content, turns, worker)
        self.assertEqual([row["id"] for row in rows], ["one", "two"])
        self.assertEqual({row["system_prompt"] for row in rows}, {"constant production prefix"})
        self.assertEqual([m['role'] for m in rows[1]['initial_messages']], ['user', 'system'])
        self.assertEqual(rows[1]['initial_messages'][-1]['text'], 'request context')
        self.assertEqual(rows[1]['user_prompt'], '오늘 뭐 할까?')
        sent = worker.calls[0][1]["configuration"]
        self.assertNotIn("retrieval", sent["dialogueContent"])
        self.assertEqual(sent["nameRuleStyle"], "response-action")
        self.assertTrue(sent["memoryClassification"])
        self.assertEqual(provenance["system_prompt_sha256"], sha256(b"constant production prefix"))
        self.assertEqual(provenance["retrieval_mode"], "disabled_for_invariant_prefix_measurement")

    def test_prefix_change_between_turns_is_rejected(self):
        class Changing(FakeWorker):
            def call(self, operation, **payload):
                result = super().call(operation, **payload)
                result["model_input"]["messages"][0]["text"] += payload["userMessage"]
                return result
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            content = root / "content.json"; content.write_text(json.dumps({"id":"x","name":"검사","persona":"정본"}))
            turns = root / "turns.json"; turns.write_text(json.dumps([
                {"id":"one","user_message":"하나","history":[]},
                {"id":"two","user_message":"둘","history":[]},
            ]))
            with self.assertRaisesRegex(ValueError, "system prefix changed"):
                compose_dialogue_fixture(content, turns, Changing())


if __name__ == "__main__":
    unittest.main()
