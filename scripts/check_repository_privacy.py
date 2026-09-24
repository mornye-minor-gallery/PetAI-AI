#!/usr/bin/env python3
"""Reject personal paths and identifiers in new commit messages and added text.

This is a high-confidence text check, not a substitute for reviewing binaries,
credentials, PR descriptions, or the repository's older history. Commit author
identities are chosen by contributors and are not screened here.
"""

from __future__ import annotations

import argparse
import re
import subprocess


HOME_PATH = re.compile(r"(?:/Users/|/home/)[A-Za-z0-9._-]+|[A-Za-z]:\\Users\\[A-Za-z0-9._-]+")
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\b")
PHONE = re.compile(r"(?<!\d)01[016789][- ]?\d{3,4}[- ]?\d{4}(?!\d)")
SAFE_CONTENT_EMAIL_DOMAINS = {"example.com", "example.org", "example.net", "users.noreply.github.com", "noreply.github.com"}
SAFE_CONTENT_EMAIL_ADDRESSES = {"noreply@github.com"}


def git(*arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments], capture_output=True, text=True, errors="replace"
    )
    if result.returncode:
        raise RuntimeError("Git could not inspect the requested commit range")
    return result.stdout


def findings(value: str) -> set[str]:
    found = set()
    if HOME_PATH.search(value):
        found.add("personal home path")
    if PHONE.search(value):
        found.add("phone number")
    if any(
        match.group().lower() not in SAFE_CONTENT_EMAIL_ADDRESSES
        and match.group().rsplit("@", 1)[1].lower() not in SAFE_CONTENT_EMAIL_DOMAINS
        for match in EMAIL.finditer(value)
    ):
        found.add("email address")
    return found


def scan_commit(commit: str) -> list[str]:
    problems = []
    message = git("show", "-s", "--format=%B", commit)
    for problem in sorted(findings(message)):
        problems.append(f"commit message: {problem}")

    diff = git(
        "show", "--first-parent", "--format=", "--no-ext-diff", "--no-textconv",
        "--unified=0", commit,
    )
    for line in diff.splitlines():
        if line.startswith("+") and not line.startswith("+++ "):
            for problem in sorted(findings(line[1:])):
                problems.append(f"added content: {problem}")
    return sorted(set(problems))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="Trusted commit before the new work")
    parser.add_argument("--head", default="HEAD", help="Commit to inspect (default: HEAD)")
    arguments = parser.parse_args()
    try:
        base = git("rev-parse", "--verify", f"{arguments.base}^{{commit}}").strip()
        head = git("rev-parse", "--verify", f"{arguments.head}^{{commit}}").strip()
        base = git("merge-base", base, head).strip()
        commits = git("rev-list", "--reverse", f"{base}..{head}").splitlines()
        violations = [(commit, scan_commit(commit)) for commit in commits]
    except RuntimeError as error:
        print(f"Privacy check could not run: {error}")
        return 2

    failed = False
    for commit, problems in violations:
        for problem in problems:
            print(f"{commit[:12]}: {problem}")
            failed = True
    if failed:
        print("Privacy check failed. Inspect the listed commits locally before pushing.")
        return 1
    print(f"Privacy check passed for {len(commits)} new commit(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
