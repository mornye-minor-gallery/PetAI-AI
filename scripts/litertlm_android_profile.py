"""Pinned Android CPU native inputs and source preparation."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import urllib.request

from litertlm_prefix_cursor import ROOT, REVISION, prepare, sha, verify_product_source

SOURCE_SHA = "7efcec573b837a882b313ae115b12cac4b6ed6a9d20673d1a91d44ddbaeede1a"
PREFILL_PATCH = ROOT / "ios/ThirdParty/LiteRTLM/Patches/cpu-prefill-chunk.patch"
PREFILL_SHA = "e3e058b0e74936d854bb8b4ec8cbc1c60c419fe8a932992e799e45cf6c3522b9"

def download(url, destination, expected):
    print("Downloading " + destination.name, flush=True)
    last = [0.0]
    def progress(blocks, size, total):
        if time.monotonic() - last[0] >= 10:
            print(f"{destination.name}: {blocks * size} / {total} bytes", flush=True)
            last[0] = time.monotonic()
    urllib.request.urlretrieve(url, destination, progress)
    if sha(destination) != expected:
        raise ValueError("Downloaded checksum mismatch: " + destination.name)


def prepare_source(source, backend="cpu"):
    """Only extract into a new directory. Existing unowned source is never patched."""
    if backend != "cpu":
        raise ValueError("Only the validated CPU profile is available")
    expected = {"source": SOURCE_SHA, "prefill": PREFILL_SHA,
                "cursor": sha(ROOT / "ios/ThirdParty/LiteRTLM/Patches/prefix-cursor.patch")}
    marker = source / ".petai-android-profile.json"
    if source.exists():
        recorded = json.loads(marker.read_text())
        if recorded["inputs"] != expected:
            raise ValueError("Native source profile changed; prepare a new source directory")
        for name, digest in recorded["files"].items():
            if sha(source / name) != digest:
                raise ValueError("Prepared source changed: " + name)
        return
    source.parent.mkdir(parents=True, exist_ok=True)
    if sha(PREFILL_PATCH) != PREFILL_SHA:
        raise ValueError("CPU prefill patch checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="native-source-", dir=source.parent) as temporary:
        stage = Path(temporary)
        archive = stage / "source.tar.gz"
        download(f"https://api.github.com/repos/mornye-minor-gallery/LiteRT-LM/tarball/{REVISION}", archive, SOURCE_SHA)
        tree = stage / "source"
        tree.mkdir()
        subprocess.run(["tar", "-xzf", str(archive), "-C", str(tree), "--strip-components=1"], check=True)
        (tree / ".petai-checkpoint-source").write_text(f"source_revision={REVISION}\n")
        subprocess.run(["patch", "-p1", "--batch", "--fuzz=0", "-i", str(PREFILL_PATCH)], cwd=tree, check=True)
        prepare(tree)
        verify_product_source(tree)
        # Record every downloaded source file, not just headers. This marker is
        # produced only from a verified archive; build reuse checks it again.
        files = {str(p.relative_to(tree)): sha(p) for p in tree.rglob("*") if p.is_file()}
        (tree / marker.name).write_text(json.dumps({"inputs": expected, "files": files}, sort_keys=True))
        shutil.move(str(tree), source)
