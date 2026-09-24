"""Privacy checks must inspect every new commit, not only the final tree."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).resolve().parents[1] / "check_repository_privacy.py"
SAFE_EMAIL = "123+contributor@users.noreply.github.com"


class RepositoryPrivacyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Contributor")
        self.git("config", "user.email", SAFE_EMAIL)
        self.commit("note.txt", "safe baseline\n")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args], cwd=self.repo, text=True, capture_output=True, check=True
        )

    def commit(self, name: str, content: str, message: str = "safe change") -> None:
        (self.repo / name).write_text(content)
        self.git("add", name)
        self.git("commit", "-qm", message)

    def check(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CHECKER), "--base", self.base],
            cwd=self.repo, text=True, capture_output=True
        )

    def test_safe_commit_passes(self) -> None:
        self.commit("note.txt", "safe baseline\nnew safe line\n")
        self.assertEqual(self.check().returncode, 0)

    def test_personal_home_path_is_rejected_without_echoing_value(self) -> None:
        private_path = "/Us" + "ers/alice/private/model.bin"
        self.commit("note.txt", f"path={private_path}\n")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(private_path, result.stdout + result.stderr)

    def test_windows_home_path_is_rejected(self) -> None:
        private_path = "C:\\Us" + "ers\\alice\\private.txt"
        self.commit("note.txt", f"path={private_path}\n")
        self.assertEqual(self.check().returncode, 1)

    def test_email_in_added_content_is_rejected(self) -> None:
        email = "alice" + "@personal.test"
        self.commit("note.txt", f"contact={email}\n")
        self.assertEqual(self.check().returncode, 1)

    def test_email_in_commit_message_is_rejected(self) -> None:
        email = "alice" + "@personal.test"
        self.commit("note.txt", "safe content\n", message=f"contact {email}")
        self.assertEqual(self.check().returncode, 1)

    def test_github_platform_email_in_added_content_is_allowed(self) -> None:
        self.commit("note.txt", "committer=noreply@github.com\n")
        self.assertEqual(self.check().returncode, 0)

    def test_added_line_starting_with_plus_is_scanned(self) -> None:
        private_path = "/Us" + "ers/alice/private/model.bin"
        self.commit("note.txt", f"++{private_path}\n")
        self.assertEqual(self.check().returncode, 1)

    def test_personal_phone_in_message_is_rejected(self) -> None:
        phone = "010" + "-1234-5678"
        self.commit("note.txt", "safe text\n", message=f"call {phone}")
        self.assertEqual(self.check().returncode, 1)

    def test_phone_without_separators_is_rejected(self) -> None:
        phone = "010" + "12345678"
        self.commit("note.txt", f"contact={phone}\n")
        self.assertEqual(self.check().returncode, 1)

    def test_removed_secret_still_fails_on_earlier_commit(self) -> None:
        private_path = "/Us" + "ers/alice/private/model.bin"
        self.commit("note.txt", f"path={private_path}\n")
        self.commit("note.txt", "safe again\n")
        self.assertEqual(self.check().returncode, 1)

    def test_contributor_author_email_is_allowed(self) -> None:
        email = "contributor" + "@gmail.com"
        self.git("config", "user.email", email)
        self.commit("note.txt", "safe content\n")
        result = self.check()
        self.assertEqual(result.returncode, 0)
        self.assertNotIn(email, result.stdout + result.stderr)

    def test_old_baseline_content_is_not_reported_as_new(self) -> None:
        private_path = "/Us" + "ers/alice/private/model.bin"
        self.commit("note.txt", f"path={private_path}\n")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.commit("another.txt", "new safe file\n")
        self.assertEqual(self.check().returncode, 0)

    def test_moving_base_branch_uses_common_ancestor(self) -> None:
        self.git("switch", "-qc", "feature")
        private_path = "/Us" + "ers/alice/private/model.bin"
        self.commit("note.txt", f"path={private_path}\n")
        self.git("switch", "-q", "-")
        self.commit("baseline.txt", "base branch advanced\n")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("switch", "-q", "feature")
        self.assertEqual(self.check().returncode, 1)


if __name__ == "__main__":
    unittest.main()
