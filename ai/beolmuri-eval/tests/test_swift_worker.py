import tempfile
from pathlib import Path
import unittest
from beolmuri_eval.config import repository
from beolmuri_eval.evaluation import load_plan
from beolmuri_eval.doctor import swift_binary
from persona_worker import Worker


class SwiftWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.worker = Worker([str(swift_binary(repository()))], Path(self.temp.name) / "swift.log")

    def tearDown(self):
        self.worker.close()
        self.temp.cleanup()

    def test_swift_owns_retry_decision_and_header_processing(self):
        baseline = load_plan().configuration
        response = self.worker.call("process", configuration=baseline, primaryChunks=["save(P=1,E=0)"])
        self.assertEqual(response["status"], "retry_required")
        response = self.worker.call("process", configuration=baseline, primaryChunks=["save(P=1,E=0)"],
                                    retryChunks=["나는 ", "엘레나야."])
        self.assertEqual(response["visible_text"], "나는 엘레나야.")
        self.assertTrue(response["retry_attempted"])
        self.assertFalse(response["memory_write_performed"])

    def test_prompt_variants_use_same_empty_history_and_production_sampling(self):
        prompts = {}
        for name, configuration in load_plan().document["variants"].items():
            prompts[name] = self.worker.call("prepare", configuration=configuration,
                                             characterName="엘레나", userMessage="아영아, 안녕?")
        self.assertEqual(len({row["user_prompt"] for row in prompts.values()}), 1)
        self.assertIn('캐릭터의 이름은 "엘레나"이다', prompts["name-rule"]["system_prompt"])
        self.assertEqual(prompts["baseline"]["sampling"]["max_output_tokens"], 4096)
        self.assertEqual(prompts["baseline"]["history"], [])
        self.assertNotEqual(prompts["baseline"]["system_prompt"], prompts["answer-only"]["system_prompt"])

    def test_name_only_yaml_reaches_swift_without_other_system_sections(self):
        config = load_plan(variant="name-only").configuration
        response = self.worker.call("prepare", configuration=config,
                                    characterName="루미", userMessage="아영아, 안녕?")
        self.assertEqual(response["configuration"], config)
        self.assertTrue(response["system_prompt"].startswith("## 답변 직전 확인: 호명과 정체성"))
        self.assertIn('캐릭터의 이름은 "루미"이다', response["system_prompt"])
        self.assertEqual(response["user_prompt"], "## 현재 사용자 입력과 회수 기억\n아영아, 안녕?")
        processed = self.worker.call("process", configuration=config,
                                     primaryChunks=["나는 루미야."])
        self.assertEqual(processed["visible_text"], "나는 루미야.")
        self.assertFalse(processed["retry_attempted"])

    def test_thinking_override_changes_sampling_but_not_persona_prompt(self):
        config = load_plan(variant="name-rule").configuration
        original = self.worker.call("prepare", configuration=config,
                                    characterName="엘레나", userMessage="아영아, 오늘 뭐 했어?")
        thinking = self.worker.call("prepare", configuration={**config, "thinking": True},
                                    characterName="엘레나", userMessage="아영아, 오늘 뭐 했어?")
        self.assertFalse(original["sampling"]["thinking"])
        self.assertTrue(thinking["sampling"]["thinking"])
        self.assertTrue(thinking["configuration"]["thinking"])
        self.assertEqual(original["system_prompt"], thinking["system_prompt"])
        self.assertEqual(original["user_prompt"], thinking["user_prompt"])

    def test_answer_only_empty_output_has_no_retry(self):
        response = self.worker.call("process", configuration=load_plan(variant="answer-only").configuration, primaryChunks=[])
        self.assertEqual(response["status"], "processed")
        self.assertFalse(response["retry_attempted"])
        self.assertFalse(response["has_visible_response"])

    def test_sampling_override_preserves_prompt_and_thinking(self):
        config = load_plan(variant="name-rule").configuration
        payload = dict(characterName="엘레나", userMessage="오늘 뭐 하고 싶어?")
        original = self.worker.call("prepare", configuration=config, **payload)
        sampling = {"temperature": 1.0, "top_k": 64, "top_p": 0.95}
        changed = self.worker.call("prepare", configuration={**config, "sampling": sampling}, **payload)
        self.assertEqual(changed["configuration"]["sampling"], sampling)
        for key, value in sampling.items():
            self.assertAlmostEqual(changed["sampling"][key], value, places=6)
        self.assertAlmostEqual(original["sampling"]["temperature"], 0.7, places=6)
        self.assertEqual(original["sampling"]["top_k"], 40)
        self.assertEqual(original["sampling"]["top_p"], 1)
        for key in ("system_prompt", "user_prompt"):
            self.assertEqual(original[key], changed[key])
        for key in ("thinking", "max_output_tokens", "filter_channel_content_from_kv_cache"):
            self.assertEqual(original["sampling"][key], changed["sampling"][key])

    def test_name_structures_use_explicit_persona(self):
        config = load_plan(variant="name-rule").configuration
        prepared = []
        for style in ("identity-statement", "response-action"):
            row = self.worker.call("prepare", configuration={**config, "nameRuleStyle": style},
                                   characterName="엘레나", userMessage="아영아, 안녕?")
            self.assertIn("검사 전용 캐릭터", row["system_prompt"])
            self.assertEqual(row["configuration"]["nameRuleStyle"], style)
            prepared.append(row)
        self.assertEqual(prepared[0]["sampling"], prepared[1]["sampling"])
        self.assertEqual(prepared[0]["user_prompt"], prepared[1]["user_prompt"])
