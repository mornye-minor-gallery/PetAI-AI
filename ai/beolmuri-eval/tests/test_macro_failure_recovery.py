"""Malformed authored macros must not terminate the shared Swift worker."""
from pathlib import Path
import tempfile
import unittest

from beolmuri_eval.config import repository
from beolmuri_eval.doctor import swift_binary
from beolmuri_eval.process import Worker


class MacroFailureRecoveryTests(unittest.TestCase):
    def test_notes_and_lore_errors_leave_worker_available_and_state_uncommitted(self):
        malformed = [
            "{{variable}}", "{{variable::}}", "{{variable::   }}",
            "{{#variable}}body{{/variable}}", "{{#variable::}}body{{/variable}}",
            "{{variable::name}}", "{{variable::.}}", "{{variable::$}}",
        ]
        base = dict(includePersona=False, includeSessionContext=True,
                    enforceCharacterName=False, memoryClassification=False)
        # Synthetic measurement isolates macro error handling from model inference.
        payload = dict(characterName="엘레나", userMessage="안녕", timeout=10,
                       tokenBudget=dict(memoryTokens=512, contextTokens=4096, outputTokens=256),
                       measurerID="test-fixed-count", measurement_handler=lambda _: 1)
        with tempfile.TemporaryDirectory() as folder:
            with Worker([str(swift_binary(repository()))], Path(folder) / "worker.log") as worker:
                pid = worker.process.pid
                for location in ("note", "lore"):
                    for macro in malformed:
                        with self.subTest(location=location, macro=macro):
                            text = "{{setvar::counter::99}}" + macro
                            config = dict(base)
                            if location == "note":
                                config["authorsNote"] = {"defaults": {"text": text, "depth": 0}}
                            else:
                                config["worldInfo"] = {"tokenBudget": 256, "entries": [
                                    {"id": "bad", "content": text, "keys": [], "constant": True,
                                     "position": "in-chat", "rules": {"depth": 0, "sticky": 2}}
                                ]}
                            with self.assertRaisesRegex(RuntimeError, "invalidMacro"):
                                worker.call("prepare", configuration=config, **payload)
                            self.assertIsNone(worker.process.poll())
                            self.assertEqual(worker.process.pid, pid)
                            normal = dict(base, authorsNote={"defaults": {
                                "text": "count={{incvar::counter}}", "depth": 0}})
                            reply = worker.call("prepare", configuration=normal, **payload)
                            self.assertIn("count=1", reply["user_prompt"])
                            self.assertEqual(reply["world_info_transaction"]["text"]["localVariables"]["counter"], "1")
                            self.assertEqual(reply["world_info_transaction"]["state"]["sticky"], {})
