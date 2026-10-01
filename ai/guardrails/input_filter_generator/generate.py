"""Build a local-only chat input policy from pinned, reviewed candidates."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import re
import subprocess
import tempfile
import unicodedata
import urllib.request
from pathlib import Path


KOREAN_SOURCE = (
    "https://raw.githubusercontent.com/Tanat05/korcen/"
    "eecd9763dbdccce3dc96ddb578ef0b6396058fa9/korcen/korcen.py"
)
ENGLISH_SOURCE = (
    "https://raw.githubusercontent.com/LDNOOBW/"
    "List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words/"
    "5faf2ba42d7b1c0977169ec3611df25a3c08eb13/en"
)
KOREAN_VARIABLES = {
    "GENERAL_PROFANITY_PATTERNS",
    "SEXUAL_PROFANITY_PATTERNS",
}
KOREAN_CHARACTERS = re.compile(r"[\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3]")
REGEX_SYNTAX = re.compile(r"[\\\[\]{}()^$*+?|.]")
ENGLISH_WORDS = re.compile(r"[a-z]+(?:[ '-][a-z]+)*")


def extract_korean(source: str) -> list[str]:
    terms: set[str] = set()
    for node in ast.parse(source).body:
        if not isinstance(node, ast.Assign):
            continue
        if not any(
            isinstance(target, ast.Name) and target.id in KOREAN_VARIABLES
            for target in node.targets
        ):
            continue
        values = ast.literal_eval(node.value)
        for value in values:
            if not isinstance(value, str):
                continue
            term = unicodedata.normalize("NFKC", value.strip()).lower()
            if 1 <= len(term) <= 40 and KOREAN_CHARACTERS.search(term) and not REGEX_SYNTAX.search(term):
                terms.add(term)
    return sorted(terms)


def extract_english(source: str) -> list[str]:
    terms = {
        unicodedata.normalize("NFKC", line.strip()).lower()
        for line in source.splitlines()
    }
    return sorted(term for term in terms if 1 <= len(term) <= 40 and ENGLISH_WORDS.fullmatch(term))


def collect_candidates(korean: list[str], english: list[str]) -> list[dict[str, str]]:
    candidates = []
    for language, terms in (("ko", korean), ("en", english)):
        for term in sorted(set(terms)):
            identifier = hashlib.sha256(f"{language}\0{term}".encode()).hexdigest()[:20]
            candidates.append({"id": identifier, "language": language, "term": term})
    return candidates


def build_policy(
    candidates: list[dict[str, str]],
    first_review: dict[str, str],
    second_review: dict[str, str],
) -> dict[str, object]:
    korean: set[str] = set()
    english: set[str] = set()
    for candidate in candidates:
        identifier = candidate["id"]
        if identifier not in first_review or identifier not in second_review:
            raise ValueError(f"missing review for candidate {identifier}")
        decisions = (first_review[identifier], second_review[identifier])
        if any(decision not in {"block", "allow", "unsure"} for decision in decisions):
            raise ValueError(f"invalid review for candidate {identifier}")
        if decisions == ("block", "block"):
            # A one-syllable substring would also reject unrelated everyday words.
            if candidate["language"] == "ko" and len(candidate["term"]) == 1:
                continue
            target = korean if candidate["language"] == "ko" else english
            target.add(candidate["term"])
    return {
        "version": 1,
        "koreanContains": sorted(korean),
        "englishWholeWords": sorted(english),
    }


def fetch_text(url: str) -> str:
    with urllib.request.urlopen(url, timeout=30) as response:
        data = response.read(3_000_001)
    if len(data) > 3_000_000:
        raise ValueError("source exceeds 3 MB limit")
    return data.decode("utf-8-sig")


def write_json(path: Path, data: object) -> None:
    repository = Path(__file__).resolve().parents[3]
    resolved = path.resolve()
    if resolved.is_relative_to(repository):
        relative = resolved.relative_to(repository)
        ignored = subprocess.run(
            ["git", "check-ignore", "-q", "--", str(relative)],
            cwd=repository,
            check=False,
        )
        if ignored.returncode != 0:
            raise ValueError("private output path must be ignored by Git")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=path.name + ".", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    fetch = subparsers.add_parser("fetch-candidates")
    fetch.add_argument("--output", type=Path, required=True)
    build = subparsers.add_parser("build-policy")
    build.add_argument("--candidates", type=Path, required=True)
    build.add_argument("--first-review", type=Path, required=True)
    build.add_argument("--second-review", type=Path, required=True)
    build.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if args.command == "fetch-candidates":
        candidates = collect_candidates(
            extract_korean(fetch_text(KOREAN_SOURCE)),
            extract_english(fetch_text(ENGLISH_SOURCE)),
        )
        write_json(args.output, candidates)
        print(f"Imported {len(candidates)} candidates into local output.")
    else:
        candidates = json.loads(args.candidates.read_text(encoding="utf-8"))
        first = json.loads(args.first_review.read_text(encoding="utf-8"))
        second = json.loads(args.second_review.read_text(encoding="utf-8"))
        policy = build_policy(candidates, first, second)
        write_json(args.output, policy)
        print(
            "Built local policy: "
            f"{len(policy['koreanContains'])} Korean, "
            f"{len(policy['englishWholeWords'])} English entries."
        )


if __name__ == "__main__":
    main()
