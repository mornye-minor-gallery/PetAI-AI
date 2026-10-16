"""Build the product Swift bridge against one verified native profile. Swift SDK 6.4 / NDK r30."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

from litertlm_prefix_cursor import ROOT, sha, verify_android, verify_android_product
from litertlm_android_profile import prepare_source


def c_source_path_map(scratch: Path) -> str:
    # BoringSSL embeds __FILE__ in release binaries; do not publish a developer's build path.
    return f"-ffile-prefix-map={scratch}=/petai-build"


def prepare_sqlite() -> None:
    subprocess.run(["sh", str(ROOT / "android/dependencies/prepare-sqlite.sh")], check=True)


def android_environment(source: Path, native: Path, backend: str) -> dict[str, str]:
    return {**os.environ, "PETAI_ANDROID_BUILD": "1", "PETAI_ANDROID_LLM_BACKEND": backend,
            "PETAI_LITERTLM_SOURCE_DIR": str(source), "PETAI_LITERTLM_LIBRARY_DIR": str(native)}


def finalize_shared_bridge(library: Path, ndk: Path) -> None:
    strips = list((ndk / "toolchains/llvm/prebuilt").glob("*/bin/llvm-strip"))
    if len(strips) != 1:
        raise ValueError("Expected one Android NDK llvm-strip executable")
    subprocess.run([str(strips[0]), "--strip-unneeded", str(library)], check=True)
    # NDK's linker identification embeds its own public Android buildbot path.
    data = library.read_bytes().replace(b"/Volumes/Android/buildbot/", b"")
    if any(path in data for path in (b"/Users/", b"/Volumes/", b"/home/")):
        raise ValueError("Android bridge contains a private build path")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--backend", choices=("cpu", "gpu"), default="cpu")
    args = parser.parse_args()
    source, native, scratch = args.source.resolve(), args.native.resolve(), args.scratch.resolve()
    ndk_home = os.environ.get("ANDROID_NDK_HOME")
    if not ndk_home:
        raise ValueError("ANDROID_NDK_HOME is required to finalize the Android bridge")
    manifest = verify_android(native, backend=args.backend)
    prepare_source(source, args.backend)
    prepare_sqlite()
    environment = android_environment(source, native, args.backend)
    command = [args.swift, "build", "--package-path", str(ROOT / "android"), "--scratch-path", str(scratch),
               "--swift-sdk", "swift-6.4.0-RELEASE_android", "--triple", "aarch64-unknown-linux-android28",
               "-c", "release", "--static-swift-stdlib", "--jobs", "2", "-Xcc", c_source_path_map(scratch),
               "--product", "PetAIAndroid"]
    print("Building Swift product bridge (2 jobs)", flush=True)
    subprocess.run(command, env=environment, check=True)
    output = Path(subprocess.check_output(command + ["--show-bin-path"], env=environment, text=True).strip())
    # Inputs must remain unchanged throughout compilation.
    if verify_android(native, backend=args.backend) != manifest:
        raise ValueError("Native engine changed during Swift compilation")
    prepare_source(source, args.backend)
    staged_bridge = native / "libPetAIAndroid.so.next"
    try:
        shutil.copyfile(output / "libPetAIAndroid.so", staged_bridge)
        finalize_shared_bridge(staged_bridge, Path(ndk_home))
        os.replace(staged_bridge, native / "libPetAIAndroid.so")
    finally:
        staged_bridge.unlink(missing_ok=True)
    bundle = native / "EdgeLLM_EdgeLLM.bundle"
    if bundle.exists(): shutil.rmtree(bundle)
    shutil.copytree(output / bundle.name, bundle)
    bridge = {"backend": args.backend, "native_manifest_sha256": sha(native / "liblitert-lm.provenance.json"),
              "bridge_sha256": sha(native / "libPetAIAndroid.so"),
              "resources": {str(p.relative_to(bundle)): sha(p) for p in bundle.rglob("*") if p.is_file()}}
    (native / "libPetAIAndroid.provenance.json").write_text(json.dumps(bridge, indent=2) + "\n")
    verify_android_product(native, backend=args.backend)
    print("Swift bridge, resources and native profile verified.", flush=True)
    print("Package this directory with both provenance files and the EdgeLLM resource bundle.", flush=True)


if __name__ == "__main__": main()
