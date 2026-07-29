from __future__ import annotations

import re
import time
from collections.abc import Callable, Iterable
from dataclasses import asdict, dataclass
from enum import Enum
from typing import Any, Protocol


class MemoryDecision(str, Enum):
    NONE = "N"
    PREFERENCE = "P"
    EVENT = "E"
    BOTH = "B"

    @classmethod
    def from_flags(
        cls,
        *,
        preference: bool,
        event: bool,
    ) -> MemoryDecision:
        if preference and event:
            return cls.BOTH
        if preference:
            return cls.PREFERENCE
        if event:
            return cls.EVENT
        return cls.NONE

    @property
    def should_save(self) -> bool:
        return self is not MemoryDecision.NONE


class MemoryHeaderFormat(str, Enum):
    LABEL = "label"
    AXES = "axes"
    SET = "set"
    FULL_AXES = "full_axes"
    WRAPPED_AXES = "wrapped_axes"


class HeaderParseKind(str, Enum):
    NEED_MORE = "need_more"
    RECOGNIZED = "recognized"
    NOT_HEADER = "not_header"
    MALFORMED = "malformed"


class HeaderSyntax(str, Enum):
    CANONICAL = "canonical"
    RECOVERED = "recovered"
    ABSENT = "absent"
    MALFORMED = "malformed"


class DecisionSource(str, Enum):
    PRIMARY = "primary"
    FALLBACK = "fallback"
    UNRESOLVED = "unresolved"


@dataclass(frozen=True)
class HeaderParseResult:
    kind: HeaderParseKind
    decision: MemoryDecision | None = None
    consumed_characters: int = 0
    syntax: HeaderSyntax | None = None


@dataclass(frozen=True)
class HeaderGateResult:
    decision: MemoryDecision | None
    syntax: HeaderSyntax
    raw_text: str
    visible_text: str
    control_text: str


@dataclass(frozen=True)
class HybridOutcome:
    request_id: str
    user_message: str
    decision: MemoryDecision
    decision_source: DecisionSource
    visible_text: str
    primary_raw_text: str
    primary_syntax: HeaderSyntax
    retry_raw_text: str | None
    retry_attempted: bool
    retry_succeeded: bool
    fallback_attempted: bool
    fallback_succeeded: bool
    should_commit: bool
    primary_seconds: float
    retry_seconds: float
    fallback_seconds: float
    total_seconds: float
    errors: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        result = asdict(self)
        result["decision"] = self.decision.value
        result["decision_source"] = self.decision_source.value
        result["primary_syntax"] = self.primary_syntax.value
        result["errors"] = list(self.errors)
        return result


class FallbackClassifier(Protocol):
    def classify(
        self,
        *,
        record_id: str,
        utterance: str,
    ) -> MemoryDecision: ...


class MemoryDecisionParser:
    _canonical = re.compile(
        r"\A[ \t]*save[ \t]*\([ \t]*([NPEB])[ \t]*\)",
        re.IGNORECASE,
    )
    _axes = re.compile(
        r"\A[ \t]*P[ \t]*=[ \t]*([01])[ \t]+"
        r"E[ \t]*=[ \t]*([01])[ \t]*",
        re.IGNORECASE,
    )
    _set = re.compile(
        r"\A[ \t]*save[ \t]*\([ \t]*"
        r"(P[ \t]*,[ \t]*E|[NPE])[ \t]*\)",
        re.IGNORECASE,
    )
    _full_axes = re.compile(
        r"\A[ \t]*Preference[ \t]*=[ \t]*([01])[ \t]+"
        r"Event[ \t]*=[ \t]*([01])[ \t]*",
        re.IGNORECASE,
    )
    _wrapped_axes = re.compile(
        r"\A[ \t]*save[ \t]*\([ \t]*"
        r"P[ \t]*=[ \t]*([01])[ \t]*,[ \t]*"
        r"E[ \t]*=[ \t]*([01])[ \t]*\)",
        re.IGNORECASE,
    )
    _recovered_slash = re.compile(
        r"\A[ \t]*([NPEB])[ \t]+/[ \t]+",
        re.IGNORECASE,
    )
    _recovered_line = re.compile(
        r"\A[ \t]*([NPEB])[ \t]*\r?\n",
        re.IGNORECASE,
    )
    _recovered_final = re.compile(
        r"\A[ \t]*([NPEB])[ \t]*\Z",
        re.IGNORECASE,
    )

    def __init__(
        self,
        *,
        header_format: MemoryHeaderFormat = MemoryHeaderFormat.LABEL,
    ) -> None:
        self.header_format = header_format

    def parse(
        self,
        text: str,
        *,
        final: bool,
    ) -> HeaderParseResult:
        if not text:
            return HeaderParseResult(
                HeaderParseKind.NOT_HEADER
                if final
                else HeaderParseKind.NEED_MORE,
                syntax=HeaderSyntax.ABSENT if final else None,
            )

        canonical = self._match_canonical(text)
        if canonical is not None:
            end = canonical.end()
            if end == len(text) and not final:
                return HeaderParseResult(HeaderParseKind.NEED_MORE)
            consumed = self._consume_separator(text, end)
            syntax = (
                HeaderSyntax.CANONICAL
                if text.startswith("\n", end)
                or text.startswith("\r\n", end)
                else HeaderSyntax.RECOVERED
            )
            return HeaderParseResult(
                kind=HeaderParseKind.RECOGNIZED,
                decision=self._decision_from_canonical(canonical),
                consumed_characters=consumed,
                syntax=syntax,
            )

        if self.header_format is not MemoryHeaderFormat.LABEL:
            return self._parse_unrecognized_structured(
                text,
                final=final,
            )

        recovered_slash = self._recovered_slash.match(text)
        if recovered_slash is not None:
            return HeaderParseResult(
                kind=HeaderParseKind.RECOGNIZED,
                decision=MemoryDecision(
                    recovered_slash.group(1).upper()
                ),
                consumed_characters=recovered_slash.end(),
                syntax=HeaderSyntax.RECOVERED,
            )

        recovered_line = self._recovered_line.match(text)
        if recovered_line is not None:
            return HeaderParseResult(
                kind=HeaderParseKind.RECOGNIZED,
                decision=MemoryDecision(
                    recovered_line.group(1).upper()
                ),
                consumed_characters=recovered_line.end(),
                syntax=HeaderSyntax.RECOVERED,
            )

        if final:
            recovered_final = self._recovered_final.fullmatch(text)
            if recovered_final is not None:
                return HeaderParseResult(
                    kind=HeaderParseKind.RECOGNIZED,
                    decision=MemoryDecision(
                        recovered_final.group(1).upper()
                    ),
                    consumed_characters=len(text),
                    syntax=HeaderSyntax.RECOVERED,
                )

        newline_end = self._first_line_end(text)
        if newline_end is not None:
            first_line = text[:newline_end]
            if self.looks_like_control(first_line):
                return HeaderParseResult(
                    kind=HeaderParseKind.MALFORMED,
                    consumed_characters=newline_end,
                    syntax=HeaderSyntax.MALFORMED,
                )
            return HeaderParseResult(
                kind=HeaderParseKind.NOT_HEADER,
                syntax=HeaderSyntax.ABSENT,
            )

        if self._could_be_control_prefix(text):
            if final:
                return HeaderParseResult(
                    kind=HeaderParseKind.MALFORMED,
                    consumed_characters=len(text),
                    syntax=HeaderSyntax.MALFORMED,
                )
            return HeaderParseResult(HeaderParseKind.NEED_MORE)

        return HeaderParseResult(
            kind=HeaderParseKind.NOT_HEADER,
            syntax=HeaderSyntax.ABSENT,
        )

    def _match_canonical(self, text: str) -> re.Match[str] | None:
        pattern = {
            MemoryHeaderFormat.LABEL: self._canonical,
            MemoryHeaderFormat.AXES: self._axes,
            MemoryHeaderFormat.SET: self._set,
            MemoryHeaderFormat.FULL_AXES: self._full_axes,
            MemoryHeaderFormat.WRAPPED_AXES: self._wrapped_axes,
        }[self.header_format]
        return pattern.match(text)

    def _decision_from_canonical(
        self,
        canonical: re.Match[str],
    ) -> MemoryDecision:
        if self.header_format in {
            MemoryHeaderFormat.AXES,
            MemoryHeaderFormat.FULL_AXES,
            MemoryHeaderFormat.WRAPPED_AXES,
        }:
            return MemoryDecision.from_flags(
                preference=canonical.group(1) == "1",
                event=canonical.group(2) == "1",
            )
        if self.header_format is MemoryHeaderFormat.SET:
            label_set = re.sub(
                r"[ \t]",
                "",
                canonical.group(1).upper(),
            )
            return {
                "N": MemoryDecision.NONE,
                "P": MemoryDecision.PREFERENCE,
                "E": MemoryDecision.EVENT,
                "P,E": MemoryDecision.BOTH,
            }[label_set]
        return MemoryDecision(canonical.group(1).upper())

    def _parse_unrecognized_structured(
        self,
        text: str,
        *,
        final: bool,
    ) -> HeaderParseResult:
        newline_end = self._first_line_end(text)
        if newline_end is not None:
            first_line = text[:newline_end]
            if self.looks_like_control(first_line):
                return HeaderParseResult(
                    kind=HeaderParseKind.MALFORMED,
                    consumed_characters=newline_end,
                    syntax=HeaderSyntax.MALFORMED,
                )
            return HeaderParseResult(
                kind=HeaderParseKind.NOT_HEADER,
                syntax=HeaderSyntax.ABSENT,
            )

        if self._could_be_structured_prefix(text):
            if final:
                return HeaderParseResult(
                    kind=HeaderParseKind.MALFORMED,
                    consumed_characters=len(text),
                    syntax=HeaderSyntax.MALFORMED,
                )
            return HeaderParseResult(HeaderParseKind.NEED_MORE)

        if self.looks_like_control(text):
            if final:
                return HeaderParseResult(
                    kind=HeaderParseKind.MALFORMED,
                    consumed_characters=len(text),
                    syntax=HeaderSyntax.MALFORMED,
                )
            return HeaderParseResult(HeaderParseKind.NEED_MORE)

        return HeaderParseResult(
            kind=HeaderParseKind.NOT_HEADER,
            syntax=HeaderSyntax.ABSENT,
        )

    def looks_like_control(self, text: str) -> bool:
        candidate = text.strip().lower()
        if not candidate:
            return False
        if self.header_format is MemoryHeaderFormat.AXES:
            return bool(re.match(r"\A[pe][ \t]*=", candidate))
        if self.header_format is MemoryHeaderFormat.FULL_AXES:
            return bool(
                re.match(
                    r"\A(?:preference|event)[ \t]*=",
                    candidate,
                )
            )
        if candidate.startswith("save"):
            return True
        return candidate[0] in {"n", "p", "e", "b"} and (
            len(candidate) == 1
            or candidate[1].isspace()
            or candidate[1] in {"/", ":", "|", "(", ")"}
        )

    def _could_be_control_prefix(self, text: str) -> bool:
        candidate = text.lstrip().lower()
        if not candidate:
            return True

        compact = re.sub(r"[ \t]", "", candidate)
        if "save(".startswith(compact):
            return True
        if compact.startswith("save("):
            return ")" not in compact

        if candidate[0] not in {"n", "p", "e", "b"}:
            return False
        if len(candidate) == 1:
            return True

        remainder = candidate[1:]
        if remainder.isspace():
            return True
        if re.fullmatch(r"[ \t]*/[ \t]*", remainder):
            return True
        if remainder.startswith("/") or remainder.startswith("|"):
            return True
        return False

    def _could_be_structured_prefix(self, text: str) -> bool:
        compact = re.sub(r"[ \t]", "", text).upper()
        if not compact:
            return True
        candidates = {
            MemoryHeaderFormat.AXES: (
                "P=0E=0",
                "P=0E=1",
                "P=1E=0",
                "P=1E=1",
            ),
            MemoryHeaderFormat.SET: (
                "SAVE(N)",
                "SAVE(P)",
                "SAVE(E)",
                "SAVE(P,E)",
            ),
            MemoryHeaderFormat.FULL_AXES: (
                "PREFERENCE=0EVENT=0",
                "PREFERENCE=0EVENT=1",
                "PREFERENCE=1EVENT=0",
                "PREFERENCE=1EVENT=1",
            ),
            MemoryHeaderFormat.WRAPPED_AXES: (
                "SAVE(P=0,E=0)",
                "SAVE(P=0,E=1)",
                "SAVE(P=1,E=0)",
                "SAVE(P=1,E=1)",
            ),
        }[self.header_format]
        return any(
            candidate.startswith(compact)
            for candidate in candidates
        )

    @staticmethod
    def _first_line_end(text: str) -> int | None:
        newline = text.find("\n")
        return None if newline < 0 else newline + 1

    @staticmethod
    def _consume_separator(text: str, start: int) -> int:
        cursor = start
        while cursor < len(text) and text[cursor] in {" ", "\t"}:
            cursor += 1
        if text.startswith("\r\n", cursor):
            return cursor + 2
        if cursor < len(text) and text[cursor] == "\n":
            return cursor + 1
        if cursor < len(text) and text[cursor] in {"/", ":", "|"}:
            cursor += 1
            while cursor < len(text) and text[cursor] in {" ", "\t"}:
                cursor += 1
        return cursor


class MemoryHeaderGate:
    def __init__(
        self,
        parser: MemoryDecisionParser | None = None,
        *,
        max_header_characters: int = 64,
    ) -> None:
        if max_header_characters <= 0:
            raise ValueError(
                "max_header_characters must be greater than zero."
            )
        self._parser = parser or MemoryDecisionParser()
        self._max_header_characters = max_header_characters
        self._pending = ""
        self._raw_parts: list[str] = []
        self._visible_parts: list[str] = []
        self._decision: MemoryDecision | None = None
        self._syntax: HeaderSyntax | None = None
        self._control_text = ""
        self._resolved = False
        self._finished = False

    def consume(self, chunk: str) -> tuple[str, ...]:
        if self._finished:
            raise RuntimeError("Cannot consume after finish().")
        if not chunk:
            return ()

        self._raw_parts.append(chunk)
        if self._resolved:
            self._visible_parts.append(chunk)
            return (chunk,)

        self._pending += chunk
        result = self._parser.parse(self._pending, final=False)
        if (
            result.kind is HeaderParseKind.NEED_MORE
            and len(self._pending) <= self._max_header_characters
        ):
            return ()
        if result.kind is HeaderParseKind.NEED_MORE:
            result = HeaderParseResult(
                kind=(
                    HeaderParseKind.MALFORMED
                    if self._parser.looks_like_control(self._pending)
                    else HeaderParseKind.NOT_HEADER
                ),
                consumed_characters=(
                    len(self._pending)
                    if self._parser.looks_like_control(self._pending)
                    else 0
                ),
                syntax=(
                    HeaderSyntax.MALFORMED
                    if self._parser.looks_like_control(self._pending)
                    else HeaderSyntax.ABSENT
                ),
            )
        return self._resolve(result)

    def finish(self) -> HeaderGateResult:
        if self._finished:
            raise RuntimeError("finish() may only be called once.")
        self._finished = True

        if not self._resolved:
            result = self._parser.parse(self._pending, final=True)
            self._resolve(result)

        return HeaderGateResult(
            decision=self._decision,
            syntax=self._syntax or HeaderSyntax.ABSENT,
            raw_text="".join(self._raw_parts),
            visible_text="".join(self._visible_parts),
            control_text=self._control_text,
        )

    def _resolve(
        self,
        result: HeaderParseResult,
    ) -> tuple[str, ...]:
        if result.kind is HeaderParseKind.NEED_MORE:
            return ()

        if result.kind is HeaderParseKind.RECOGNIZED:
            consumed = result.consumed_characters
            self._decision = result.decision
            self._syntax = result.syntax or HeaderSyntax.RECOVERED
            self._control_text = self._pending[:consumed]
            visible = self._pending[consumed:]
        elif result.kind is HeaderParseKind.MALFORMED:
            consumed = result.consumed_characters
            self._syntax = HeaderSyntax.MALFORMED
            self._control_text = self._pending[:consumed]
            visible = self._pending[consumed:]
        else:
            self._syntax = HeaderSyntax.ABSENT
            visible = self._pending

        self._pending = ""
        self._resolved = True
        if visible:
            self._visible_parts.append(visible)
            return (visible,)
        return ()


class HybridMemoryHarness:
    def __init__(
        self,
        *,
        parser: MemoryDecisionParser | None = None,
        max_header_characters: int = 64,
    ) -> None:
        self._parser = parser or MemoryDecisionParser()
        self._max_header_characters = max_header_characters

    def run(
        self,
        *,
        request_id: str,
        record_id: str,
        user_message: str,
        primary_generation: Callable[[], Iterable[str]],
        retry_generation: Callable[[str], Iterable[str]],
        fallback_classifier: FallbackClassifier,
    ) -> HybridOutcome:
        started = time.perf_counter()
        errors: list[str] = []

        primary_started = time.perf_counter()
        try:
            primary = self._decode(primary_generation())
        except Exception as error:
            primary_seconds = time.perf_counter() - primary_started
            errors.append(
                f"primary_generation_failed: {type(error).__name__}: {error}"
            )
            return HybridOutcome(
                request_id=request_id,
                user_message=user_message,
                decision=MemoryDecision.NONE,
                decision_source=DecisionSource.UNRESOLVED,
                visible_text="",
                primary_raw_text="",
                primary_syntax=HeaderSyntax.ABSENT,
                retry_raw_text=None,
                retry_attempted=False,
                retry_succeeded=False,
                fallback_attempted=False,
                fallback_succeeded=False,
                should_commit=False,
                primary_seconds=primary_seconds,
                retry_seconds=0.0,
                fallback_seconds=0.0,
                total_seconds=time.perf_counter() - started,
                errors=tuple(errors),
            )
        primary_seconds = time.perf_counter() - primary_started

        decision = primary.decision
        decision_source = (
            DecisionSource.PRIMARY
            if decision is not None
            else DecisionSource.UNRESOLVED
        )
        visible_text = primary.visible_text.strip()
        retry_raw_text: str | None = None
        retry_attempted = False
        retry_succeeded = False
        retry_seconds = 0.0

        if not visible_text:
            retry_attempted = True
            retry_started = time.perf_counter()
            try:
                retry = self._decode(
                    retry_generation(primary.raw_text)
                )
                retry_raw_text = retry.raw_text
                visible_text = retry.visible_text.strip()
                retry_succeeded = bool(visible_text)
                if not retry_succeeded:
                    errors.append("retry_missing_visible_body")
            except Exception as error:
                errors.append(
                    "retry_generation_failed: "
                    f"{type(error).__name__}: {error}"
                )
            retry_seconds = time.perf_counter() - retry_started

        fallback_attempted = False
        fallback_succeeded = False
        fallback_seconds = 0.0
        if decision is None and visible_text:
            fallback_attempted = True
            fallback_started = time.perf_counter()
            try:
                decision = fallback_classifier.classify(
                    record_id=record_id,
                    utterance=user_message,
                )
                decision_source = DecisionSource.FALLBACK
                fallback_succeeded = True
            except Exception as error:
                errors.append(
                    f"fallback_failed: {type(error).__name__}: {error}"
                )
            fallback_seconds = time.perf_counter() - fallback_started

        if decision is None:
            decision = MemoryDecision.NONE
            decision_source = DecisionSource.UNRESOLVED

        return HybridOutcome(
            request_id=request_id,
            user_message=user_message,
            decision=decision,
            decision_source=decision_source,
            visible_text=visible_text,
            primary_raw_text=primary.raw_text,
            primary_syntax=primary.syntax,
            retry_raw_text=retry_raw_text,
            retry_attempted=retry_attempted,
            retry_succeeded=retry_succeeded,
            fallback_attempted=fallback_attempted,
            fallback_succeeded=fallback_succeeded,
            should_commit=bool(visible_text) and decision.should_save,
            primary_seconds=primary_seconds,
            retry_seconds=retry_seconds,
            fallback_seconds=fallback_seconds,
            total_seconds=time.perf_counter() - started,
            errors=tuple(errors),
        )

    def _decode(self, chunks: Iterable[str]) -> HeaderGateResult:
        gate = MemoryHeaderGate(
            self._parser,
            max_header_characters=self._max_header_characters,
        )
        for chunk in chunks:
            gate.consume(chunk)
        return gate.finish()


class IdempotentCommitLedger:
    def __init__(self) -> None:
        self._committed_request_ids: set[str] = set()
        self.attempts = 0
        self.accepted = 0
        self.duplicates = 0

    def commit(
        self,
        *,
        request_id: str,
        decision: MemoryDecision,
    ) -> bool:
        if not decision.should_save:
            return False
        self.attempts += 1
        if request_id in self._committed_request_ids:
            self.duplicates += 1
            return False
        self._committed_request_ids.add(request_id)
        self.accepted += 1
        return True


def contains_control_leak(text: str) -> bool:
    return bool(
        re.match(
            r"\A\s*(?:save\s*\(|(?:P|E|Preference|Event)\s*="
            r"|[NPEB]\s*(?:/|\r?\n|\Z))",
            text,
            re.IGNORECASE,
        )
    )
