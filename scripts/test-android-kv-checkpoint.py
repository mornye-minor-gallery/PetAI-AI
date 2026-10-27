"""Compare cold, cached, saved and restored native output on an Android target.

Only synthetic dialogue is used. GPU must be selected explicitly on a supported
device; a GPU failure never retries on CPU. Logs/results survive, binaries do not.
"""
import argparse
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import uuid

from litertlm_prefix_cursor import ROOT, sha, verify_android
from litertlm_android_profile import prepare_source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--native", required=True, type=Path)
    parser.add_argument("--ndk", required=True, type=Path)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--model", required=True, help="Existing model path on the target")
    parser.add_argument("--backend", choices=("cpu", "gpu"), required=True)
    parser.add_argument("--context", type=int, default=8192)
    parser.add_argument("--result", required=True, type=Path)
    args = parser.parse_args()
    native, source = args.native.resolve(), args.source.resolve()
    profile = verify_android(native)
    if args.backend == "gpu" and profile["backend"] != "gpu":
        raise ValueError("GPU run requires a GPU native build")
    prepare_source(source, profile["backend"])
    args.result.mkdir(parents=True, exist_ok=False)
    adb = [args.adb, "-s", args.serial]
    subprocess.run(adb + ["shell", "test -f " + shlex.quote(args.model)], check=True)
    device_memory = subprocess.check_output(adb + ["shell", "cat /proc/meminfo"], text=True)
    memory_kib = int(next(line for line in device_memory.splitlines() if line.startswith("MemTotal:")).split()[1])
    if memory_kib < 4_000_000:
        raise ValueError("At least 4 GB target RAM is required; use an 8 GB emulator")
    remote = "/data/local/tmp/petai-kv-" + uuid.uuid4().hex
    results = []
    with tempfile.TemporaryDirectory(prefix="kv-probe-", dir=args.result) as temporary:
        stage = Path(temporary)
        compiler = args.ndk / "toolchains/llvm/prebuilt/darwin-x86_64"
        tests = ROOT / "ios/ThirdParty/LiteRTLM/Tests/GPUCheckpoint"
        subprocess.run([str(compiler / "bin/aarch64-linux-android28-clang++"),
            "-std=c++17", "-O2", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
            "-I", str(source), str(tests / "probe.cc"), "-L", str(native), "-llitert-lm",
            "-Wl,-rpath,$ORIGIN", "-o", str(stage / "libcheckpoint_probe.so")], check=True)
        subprocess.run([str(compiler / "bin/aarch64-linux-android28-clang"),
            "-O2", "-Wall", "-Wextra", "-Werror", str(tests / "launcher.c"), "-ldl",
            "-o", str(stage / "probe")], check=True)
        libraries = ["liblitert-lm.so", *profile.get("libraries", {})]
        for name in libraries:
            shutil.copyfile(native / name, stage / name)
        shutil.copyfile(compiler / "sysroot/usr/lib/aarch64-linux-android/libc++_shared.so", stage / "libc++_shared.so")
        prefix = ("<|turn>system\nAnswer briefly.<turn|>\n"
                  "<|turn>user\nMy favourite colour is turquoise.<turn|>\n"
                  "<|turn>model\nNoted.<turn|>\n")
        (stage / "prefix.txt").write_text(prefix)
        (stage / "followup.txt").write_text(prefix + "<|turn>user\nWhat is my favourite colour?<turn|>\n<|turn>model\n<|channel>final\n")
        (args.result / "inputs.json").write_text(json.dumps({
            "native_profile": profile, "backend": args.backend, "context": args.context,
            "memory_kib": memory_kib, "probe_sha256": sha(stage / "libcheckpoint_probe.so"),
            "prefix": prefix, "full": (stage / "followup.txt").read_text()}, indent=2))
        subprocess.run(adb + ["shell", "mkdir -p " + remote + "/compile-cache"], check=True)
        try:
            subprocess.run(adb + ["push", str(stage) + "/.", remote + "/"], check=True)
            subprocess.run(adb + ["shell", "chmod 755 " + remote + "/probe"], check=True)
            for index, mode in enumerate(("baseline", "save", "restore", "cold"), 1):
                log = args.result / (mode + ".log")
                command = (f"cd {remote} && export LD_LIBRARY_PATH={remote} && "
                           f"echo $$ > probe.pid && exec ./probe {args.backend} {mode} "
                           f"{shlex.quote(args.model)} {remote} {remote} {args.context}")
                start = time.monotonic()
                print(f"[{index}/4] {mode}", flush=True)
                with log.open("w") as output:
                    process = subprocess.Popen(adb + ["shell", command], stdout=output, stderr=subprocess.STDOUT)
                    try:
                        while process.poll() is None:
                            try: process.wait(timeout=15)
                            except subprocess.TimeoutExpired:
                                elapsed = time.monotonic() - start
                                print(f"[{index}/4] {mode}: {elapsed:.0f}s; see {log.name}", flush=True)
                                if elapsed > 900:
                                    raise TimeoutError("Native probe exceeded 900 seconds")
                    finally:
                        if process.poll() is None:
                            # This PID is written by our unique remote invocation.
                            subprocess.run(adb + ["shell", f"kill -9 $(cat {remote}/probe.pid)"], check=False)
                            process.terminate()
                            process.wait()
                if process.returncode:
                    raise RuntimeError(f"{mode} exited {process.returncode}; inspect {log.name}")
                result = next((line[7:] for line in log.read_text().splitlines() if line.startswith("RESULT ")), None)
                if result is None: raise ValueError("No result: " + mode)
                results.append(json.loads(result))
                (args.result / "results.json").write_text(json.dumps(results, indent=2, ensure_ascii=False))
                print(f"[{index}/4] {mode}: {results[-1]['output']!r}", flush=True)
        finally:
            subprocess.run(adb + ["shell", "rm -r " + remote], check=True)
    outputs = {row["output"] for row in results}
    if len(outputs) != 1 or "turquoise" not in results[0]["output"].lower():
        raise AssertionError("Cache output equivalence or fixture recall failed; inspect results.json")
    print("PASS cold/cached/save/restore output equality and fixture recall", flush=True)


if __name__ == "__main__": main()
