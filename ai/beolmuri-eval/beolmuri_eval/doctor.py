import json
from pathlib import Path
import shutil
import tempfile
from .config import file_sha, model_artifact, model_path, python_path, repository, SCOPE
from .judge import grade
from .evaluation import load_plan
from .process import execute, heartbeat, Worker


def swift_binary(root):
    return root / "ai/beolmuri-eval/swift/.build/debug/beolmuri-swift-worker"


def build(root):
    execute(["swift", "build", "--package-path", str(root / "ai/beolmuri-eval/swift")], timeout=300)
    return swift_binary(root)


def inspect_environment(model=None, litert_python=None, codex="codex", probe=False, *, show_progress=True, judge_settings=None):
    root = repository()
    judge_settings = judge_settings if judge_settings is not None else load_plan().judge
    checks = []
    def check(name, callback):
        try:
            detail = callback()
            checks.append({"name": name, "status": "pass", "detail": detail})
            return detail
        except Exception as error:
            checks.append({"name": name, "status": "fail", "detail": str(error)})
            return None

    artifact = model_artifact(root)
    path = model_path(model)
    def verify_model():
        if not path.is_file() or path.stat().st_size != artifact["bytes"]:
            raise ValueError("deployment model is missing or has a different file size; set BEOLMURI_EVAL_MODEL")
        if show_progress:
            heartbeat("배포 모델 SHA-256 확인")
        actual = file_sha(path)
        if actual != artifact["sha256"]:
            raise ValueError("model SHA-256 differs from the product registry")
        return {"path": str(path), "sha256": actual, "revision": artifact["revision"],
                "repository": artifact["repository"], "format": "litertlm",
                "quantization": "Gemma 4 mobile mixed-precision QAT"}
    verified = check("deployment_model", verify_model)
    interpreter = check("litert_python", lambda: python_path(litert_python))
    version = check("codex_cli", lambda: execute([codex, "--version"], timeout=10)[0].strip())
    check("swift_toolchain", lambda: execute(["swift", "--version"], timeout=10)[0].strip())
    def verify_worker():
        binary = swift_binary(root)
        if not binary.is_file():
            raise ValueError("Swift worker missing; run beolmuri-eval build")
        sources = list((root / "ios/EdgeLLM/Sources").rglob("*.swift"))
        sources += list((root / "ai/beolmuri-eval/swift/Sources").rglob("*.swift"))
        sources += [root / "ios/EdgeLLM/Package.swift", root / "ai/beolmuri-eval/swift/Package.swift"]
        if any(p.stat().st_mtime > binary.stat().st_mtime for p in sources):
            raise ValueError("Swift worker is stale; run beolmuri-eval build")
        return str(binary)
    check("swift_worker", verify_worker)
    with tempfile.TemporaryDirectory(prefix="beolmuri-doctor-") as temp:
        if interpreter:
            def runtime_probe():
                with Worker([interpreter, str(Path(__file__).with_name("native_worker.py"))], Path(temp)/"native.log") as worker:
                    result = worker.call("probe", timeout=20)
                    if result["version"] != "0.13.1":
                        raise ValueError("native adapter requires litert-lm 0.13.1")
                    return result
            check("litert_native_library", runtime_probe)
        if probe and verified and interpreter:
            def generation_probe():
                with Worker([interpreter, str(Path(__file__).with_name("native_worker.py"))], Path(temp)/"generate.log") as worker:
                    worker.call("load", timeout=180, model=str(path), cache_dir=temp)
                    worker.call("start", system_prompt="짧게 한국어로 답해.", seed=0,
                                sampling={"temperature": 0.7, "top_k": 40, "top_p": 1.0,
                                          "max_output_tokens": 32, "thinking": False,
                                          "filter_channel_content_from_kv_cache": True})
                    result = worker.call("generate", message="안녕?", timeout=90)
                    if not "".join(result["chunks"]).strip():
                        raise ValueError("model probe produced no visible text")
                    return result
            check("gemma_generation", generation_probe)
        if probe and version:
            case = {"kind": "wrong_name", "character_name": "엘레나", "called_name": "아영",
                    "user_message": "아영아, 안녕?"}
            def judge_probe():
                judgment, _ = grade(case, "나는 엘레나야. 안녕!", codex=codex, settings=judge_settings)
                if judgment["label"] != "identity_maintained":
                    raise ValueError("judge failed the identity-correction calibration example")
                return judgment
            check("luna_judge", judge_probe)
    return {"ready": all(item["status"] == "pass" for item in checks), "checks": checks,
            "scope": SCOPE, "full_product_pipeline": "UNVERIFIED: scene and memory are fixed fixtures",
            "runtime_parity": "Mac LiteRT-LM 0.13.1; mobile fork 0.14.0 is not the same runtime",
            "judge": {"provider": "codex-cli", "model": judge_settings["model"], "reasoning_effort": judge_settings["reasoning_effort"],
                      "access": "probed" if probe else "UNVERIFIED: use --probe"}}
