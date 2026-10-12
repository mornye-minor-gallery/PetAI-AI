"""Build the product Swift bridge against one verified native profile. Swift SDK 6.4 / NDK r30."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

from litertlm_prefix_cursor import ROOT, sha, verify_android, verify_android_product
from litertlm_android_profile import prepare_source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--backend", choices=("cpu",), default="cpu")
    args = parser.parse_args()
    source, native, scratch = args.source.resolve(), args.native.resolve(), args.scratch.resolve()
    manifest = verify_android(native, backend=args.backend)
    prepare_source(source, args.backend)
    subprocess.run(["sh", str(ROOT / "android/poc/swift-android/prepare-core-sqlite.sh")], check=True)
    environment = {**os.environ, "PETAI_ANDROID_CORE_POC": "1", "PETAI_ANDROID_LLM_BACKEND": args.backend,
                   "PETAI_LITERTLM_SOURCE_DIR": str(source), "PETAI_LITERTLM_LIBRARY_DIR": str(native)}
    command = [args.swift, "build", "--package-path", str(ROOT / "android"), "--scratch-path", str(scratch),
               "--swift-sdk", "swift-6.4.0-RELEASE_android", "--triple", "aarch64-unknown-linux-android28",
               "-c", "release", "--static-swift-stdlib", "--jobs", "2", "--product", "PetAIAndroid"]
    print("Building Swift product bridge (2 jobs)", flush=True)
    subprocess.run(command, env=environment, check=True)
    output = Path(subprocess.check_output(command + ["--show-bin-path"], env=environment, text=True).strip())
    # Inputs must remain unchanged throughout compilation.
    if verify_android(native, backend=args.backend) != manifest:
        raise ValueError("Native engine changed during Swift compilation")
    prepare_source(source, args.backend)
    shutil.copyfile(output / "libPetAIAndroid.so", native / "libPetAIAndroid.so")
    bundle = native / "EdgeLLM_EdgeLLM.bundle"
    if bundle.exists(): shutil.rmtree(bundle)
    shutil.copytree(output / bundle.name, bundle)
    bridge = {"backend": args.backend, "native_manifest_sha256": sha(native / "liblitert-lm.provenance.json"),
              "bridge_sha256": sha(native / "libPetAIAndroid.so"),
              "resources": {str(p.relative_to(bundle)): sha(p) for p in bundle.rglob("*") if p.is_file()}}
    (native / "libPetAIAndroid.provenance.json").write_text(json.dumps(bridge, indent=2) + "\n")
    verify_android_product(native, backend=args.backend)
    print("Swift bridge, resources and native profile verified.", flush=True)


if __name__ == "__main__": main()
