"""Shared native cursor patch and Android engine identity checks."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "ios/ThirdParty/LiteRTLM/Patches/prefix-cursor.patch"
PATCH_SHA = "16d26ab9958e1e31442cb5e1f62ec34e0d1141c118ff93c00fc9bed9f839f148"
RELATIVE = "runtime/framework/resource_management/resource_manager.cc"
BEFORE_SHA = "92414e5238e6abab600366182049629001973c0cb6d6f3b3de31b933684f2648"
AFTER_SHA = "ba24e591952768b2ec9167bfc23bff2eea24b24d7427ee08595846edfbb9ec2e"
REVISION = "939b09f5ac92974bb4a7df430d440c2b8780941e"
# These inputs distinguish the product CPU checkpoint format from experimental
# GPU checkpoint builds, and preserve the existing static-prefill policy.
SOURCE_HASHES = {
    "runtime/executor/kv_checkpoint.cc": "a0571d2941b231b65364aa356e71124b4bb69a9536c204703f07c29f46b7209b",
    "runtime/executor/llm_litert_compiled_model_executor.cc": "39cda641048d73496a30c519c848cfe860031e02e20ba69e62f54920fdf197a2",
    "runtime/executor/BUILD": "ee6b4f8710d7d1fa574b054ac0b209cad4119483f789f6095fc9d09bc1335d21",
    "runtime/executor/cpu_prefill_chunk.h": "c329df678ca84fe12bc8139a0ee7dc3013a3d5efeaec3d95fd37f468ffd81649",
}


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_patch():
    if sha(PATCH) != PATCH_SHA:
        raise ValueError("Prefix cursor patch checksum mismatch")


def prepare(source):
    check_patch()
    current = sha(source / RELATIVE)
    if current == AFTER_SHA:
        return
    if current != BEFORE_SHA:
        raise ValueError("Prefix cursor source mismatch; use the pinned clean source")
    subprocess.run(["patch", "-p1", "--batch", "--forward", "--fuzz=0",
                    "-i", str(PATCH)], cwd=source, check=True)
    if sha(source / RELATIVE) != AFTER_SHA:
        raise ValueError("Patched prefix cursor source checksum mismatch")


def verify_product_source(source):
    marker = (source / ".petai-checkpoint-source").read_text()
    if f"source_revision={REVISION}\n" not in marker:
        raise ValueError("Native source revision mismatch")
    for name, expected in {RELATIVE: AFTER_SHA, **SOURCE_HASHES}.items():
        if sha(source / name) != expected:
            raise ValueError("Native compiled input mismatch: " + name)


def identity():
    check_patch()
    return {"source_revision": REVISION, "prefix_cursor_patch_sha256": PATCH_SHA,
            "resource_manager_sha256": AFTER_SHA}


def write_android_manifest(directory, backend="cpu"):
    # Called only after a successful build from verified sources, never used to
    # bless an arbitrary existing engine. Hashes bind the copied binary to it.
    manifest = {**identity(), "engine_sha256": sha(directory / "liblitert-lm.so"), "backend": backend}
    (directory / "liblitert-lm.provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")


def verify_android(directory, backend=None):
    manifest = json.loads((directory / "liblitert-lm.provenance.json").read_text())
    for key, expected in identity().items():
        if manifest.get(key) != expected:
            raise ValueError("Android engine provenance mismatch: " + key)
    if manifest.get("engine_sha256") != sha(directory / "liblitert-lm.so"):
        raise ValueError("Android engine binary checksum mismatch")
    actual = manifest.get("backend")
    if actual != "cpu" or (backend is not None and actual != backend):
        raise ValueError("Android engine backend mismatch")
    return manifest


def verify_ios(directory):
    expected = subprocess.run(["bash", str(ROOT / "scripts/prepare-ios-native-dependencies.sh"),
                               "--print-config"], check=True, capture_output=True, text=True).stdout
    if (directory / "CLiteRTLM.provenance").read_text().strip() != expected.strip():
        raise ValueError("iOS engine provenance mismatch; rebuild the native framework")
    lines = (directory / "CLiteRTLM.binary-sha256").read_text().splitlines()
    recorded = dict(line.split(maxsplit=1)[::-1] for line in lines)
    names = {f"CLiteRTLM.xcframework/{arch}/CLiteRTLM.framework/CLiteRTLM"
             for arch in ("ios-arm64", "ios-arm64-simulator")}
    if set(recorded) != names or len(lines) != len(names):
        raise ValueError("iOS engine binary manifest must contain both expected slices")
    for name in names:
        if sha(directory / name) != recorded[name]:
            raise ValueError("iOS engine binary checksum mismatch: " + name)


def verify_android_product(directory, backend):
    manifest = verify_android(directory, backend=backend)
    bridge = json.loads((directory / "libPetAIAndroid.provenance.json").read_text())
    if bridge.get("backend") != manifest["backend"] or bridge.get("native_manifest_sha256") != sha(directory / "liblitert-lm.provenance.json"):
        raise ValueError("Android Swift/native profile mismatch; rebuild the Swift bridge")
    if bridge.get("bridge_sha256") != sha(directory / "libPetAIAndroid.so"):
        raise ValueError("Android Swift bridge binary checksum mismatch")
    bundle = directory / "EdgeLLM_EdgeLLM.bundle"
    resources = {str(p.relative_to(bundle)): sha(p) for p in bundle.rglob("*") if p.is_file()}
    if not resources or resources != bridge.get("resources"):
        raise ValueError("Android Swift resources mismatch")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--identity", action="store_true")
    action.add_argument("--prepare", type=Path)
    action.add_argument("--verify-android", type=Path)
    action.add_argument("--verify-android-product", type=Path)
    action.add_argument("--verify-ios", type=Path)
    parser.add_argument("--backend", choices=("cpu",), default="cpu")
    args = parser.parse_args()
    if args.identity:
        print("prefix_cursor_patch_sha256=" + identity()["prefix_cursor_patch_sha256"])
    elif args.prepare:
        prepare(args.prepare)
    elif args.verify_android:
        verify_android(args.verify_android)
    elif args.verify_android_product:
        verify_android_product(args.verify_android_product, args.backend)
    else:
        verify_ios(args.verify_ios)


if __name__ == "__main__":
    main()
