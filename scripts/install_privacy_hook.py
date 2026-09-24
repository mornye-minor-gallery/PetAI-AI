#!/usr/bin/env python3
"""Install the repository privacy pre-push hook for this local Git clone."""

from pathlib import Path
import shutil
import subprocess
import sys


MARKER = "# Managed by repository privacy hook installer"


def main() -> int:
    source_root = Path(__file__).resolve().parents[1]
    hook_source = source_root / ".githooks" / "pre-push"
    checker_source = source_root / "scripts" / "check_repository_privacy.py"
    custom_hooks = subprocess.run(
        ["git", "config", "--get", "core.hooksPath"], capture_output=True, text=True,
    )
    if custom_hooks.returncode == 0 and custom_hooks.stdout.strip():
        print("A custom Git hooks path is configured; no hook was installed.", file=sys.stderr)
        return 1
    result = subprocess.run(
        ["git", "rev-parse", "--path-format=absolute", "--git-path", "hooks"],
        capture_output=True, text=True,
    )
    if result.returncode:
        print("Run this installer from inside the target Git clone.", file=sys.stderr)
        return 2

    hooks = Path(result.stdout.strip())
    hook = hooks / "pre-push"
    managed = hooks / "repository-privacy"
    marker_file = managed / "managed-by-installer"
    if hook.is_symlink() or (hook.exists() and MARKER not in hook.read_text().splitlines()[:2]):
        print("An unrelated pre-push hook exists; leaving it unchanged.", file=sys.stderr)
        return 1
    if managed.is_symlink() or (managed.exists() and (
        not marker_file.is_file() or marker_file.read_text() != MARKER + "\n"
    )):
        print("An unrelated repository-privacy hook directory exists; leaving it unchanged.", file=sys.stderr)
        return 1

    managed.mkdir(parents=True, exist_ok=True)
    marker_file.write_text(MARKER + "\n")
    shutil.copyfile(checker_source, managed / "check_repository_privacy.py")
    shutil.copyfile(hook_source, hook)
    hook.chmod(0o755)
    print("Privacy pre-push hook installed for this Git clone and its worktrees.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
