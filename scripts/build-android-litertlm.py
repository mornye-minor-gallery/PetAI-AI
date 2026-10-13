"""Build a pinned CPU Android engine and its provenance (Bazel 7.6.1, NDK r28b)."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from litertlm_prefix_cursor import ROOT, write_android_manifest, verify_android
from litertlm_android_profile import prepare_source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--bazel", required=True)
    parser.add_argument("--output-base", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "android/.artifacts")
    parser.add_argument("--backend", choices=("cpu",), default="cpu")
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    prepare_source(source, args.backend)
    # Reject a second product build on this source tree. Other tools must not
    # mutate the caller's exclusively owned source during compilation.
    lock = source / ".petai-product-build-lock"
    lock.mkdir()
    try:
        prepare_source(source, args.backend)
        print(f"Building product {args.backend} engine (4 jobs; Bazel progress every 15s)", flush=True)
        subprocess.run([args.bazel, "--output_base=" + str(args.output_base.resolve()),
            "build", "--config=android_arm64", "--define=LITERT_LM_FST_CONSTRAINTS_DISABLED=1",
            "--linkopt=-Wl,-z,max-page-size=16384", "--linkopt=-Wl,-z,common-page-size=16384",
            "--jobs=4", "--progress_report_interval=15", "//c:litert-lm"], cwd=source, check=True)
        prepare_source(source, args.backend)
        output.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="engine-", dir=output) as temporary:
            stage = Path(temporary)
            shutil.copyfile(source / "bazel-bin/c/liblitert-lm.so", stage / "liblitert-lm.so")
            write_android_manifest(stage, backend=args.backend)
            # Publish provenance last. A concurrent reader fails closed while
            # the binary and provenance are being replaced.
            for binary in stage.glob("*.so"):
                os.replace(binary, output / binary.name)
            os.replace(stage / "liblitert-lm.provenance.json", output / "liblitert-lm.provenance.json")
        verify_android(output, backend=args.backend)
        print("Product engine and matching provenance ready.", flush=True)
        print("Rebuild the matching Swift bridge, then publish approved inputs with scripts/build_inputs.py publish.", flush=True)
    finally:
        lock.rmdir()


if __name__ == "__main__":
    main()
