"""The local privacy hook must reject unsafe commits before Git sends them."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "install_privacy_hook.py"
SAFE_EMAIL = "123+contributor@users.noreply.github.com"


class PrivacyHookTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name) / "repo"
        self.repo.mkdir()
        self.remote = Path(self.directory.name) / "remote.git"
        self.git("init", "-q")
        self.git("config", "user.name", "Contributor")
        self.git("config", "user.email", SAFE_EMAIL)
        (self.repo / "note.txt").write_text("baseline\n")
        self.git("add", "note.txt")
        self.git("commit", "-qm", "safe baseline")
        self.git("branch", "-M", "main")
        subprocess.run(["git", "init", "--bare", "-q", str(self.remote)], check=True)
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-qu", "origin", "main")

    def git(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args], cwd=self.repo, text=True, capture_output=True, check=check
        )

    def install(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(INSTALLER)],
            cwd=self.repo, text=True, capture_output=True
        )

    def commit(self, content: str) -> None:
        (self.repo / "note.txt").write_text(content)
        self.git("add", "note.txt")
        self.git("commit", "-qm", "safe change")

    def test_safe_new_branch_push_passes(self) -> None:
        self.assertEqual(self.install().returncode, 0)
        self.git("switch", "-qc", "feature")
        self.commit("baseline\nsafe change\n")
        self.assertEqual(self.git("push", "-q", "origin", "feature", check=False).returncode, 0)

    def test_unsafe_new_branch_push_is_rejected_before_transfer(self) -> None:
        self.assertEqual(self.install().returncode, 0)
        self.git("switch", "-qc", "feature")
        private_path = "/Us" + "ers/alice/private/model.bin"
        self.commit(f"baseline\n{private_path}\n")
        result = self.git("push", "-q", "origin", "feature", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(private_path, result.stdout + result.stderr)
        self.assertEqual(self.git("ls-remote", "--heads", "origin", "feature").stdout, "")

    def test_unsafe_update_to_existing_branch_is_rejected(self) -> None:
        self.assertEqual(self.install().returncode, 0)
        self.git("switch", "-qc", "feature")
        self.commit("baseline\nsafe change\n")
        self.git("push", "-q", "origin", "feature")
        self.commit("baseline\nsafe change\n" + "/Us" + "ers/alice/private\n")
        self.assertNotEqual(
            self.git("push", "-q", "origin", "feature", check=False).returncode, 0
        )

    def test_installed_hook_applies_to_another_worktree(self) -> None:
        self.assertEqual(self.install().returncode, 0)
        worktree = Path(self.directory.name) / "secondary"
        self.git("worktree", "add", "-qb", "secondary", str(worktree))
        (worktree / "note.txt").write_text("baseline\n" + "/Us" + "ers/alice/private\n")
        for args in (("add", "note.txt"), ("commit", "-qm", "safe change")):
            subprocess.run(["git", *args], cwd=worktree, check=True, capture_output=True)
        result = subprocess.run(
            ["git", "push", "-q", "origin", "secondary"],
            cwd=worktree, text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("ls-remote", "--heads", "origin", "secondary").stdout, "")

    def test_installation_is_idempotent(self) -> None:
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.install().returncode, 0)

    def test_foreign_hook_is_not_overwritten(self) -> None:
        hook = self.repo / ".git" / "hooks" / "pre-push"
        hook.write_text("#!/bin/sh\nexit 0\n")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(hook.read_text(), "#!/bin/sh\nexit 0\n")

    def test_custom_hooks_path_is_not_falsely_reported_as_installed(self) -> None:
        self.git("config", "core.hooksPath", ".custom-hooks")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse((self.repo / ".git" / "hooks" / "pre-push").exists())


if __name__ == "__main__":
    unittest.main()
