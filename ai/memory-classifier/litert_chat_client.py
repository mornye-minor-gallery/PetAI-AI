from __future__ import annotations

import json
import urllib.error
import urllib.request
from collections.abc import Iterator
from typing import Any


class LiteRTChatClientError(RuntimeError):
    pass


class LiteRTChatClient:
    def __init__(
        self,
        *,
        base_url: str,
        model: str,
        system_prompt: str,
        temperature: float,
        top_p: float,
        max_tokens: int,
        timeout_seconds: float,
    ) -> None:
        self._endpoint = (
            base_url.rstrip("/") + "/chat/completions"
        )
        self._model = model
        self._system_prompt = system_prompt
        self._temperature = temperature
        self._top_p = top_p
        self._max_tokens = max_tokens
        self._timeout_seconds = timeout_seconds

    def stream_primary(self, user_message: str) -> Iterator[str]:
        messages = [
            {"role": "system", "content": self._system_prompt},
            {"role": "user", "content": user_message},
        ]
        yield from self._stream(messages)

    def stream_retry(
        self,
        *,
        user_message: str,
        previous_output: str,
    ) -> Iterator[str]:
        messages = [
            {"role": "system", "content": self._system_prompt},
            {"role": "user", "content": user_message},
            {"role": "assistant", "content": previous_output},
            {
                "role": "user",
                "content": (
                    "직전 사용자 발화에 직접 반응하는 자연스러운 한국어 "
                    "답변 한 문장만 작성하세요. 사과하거나 지시를 "
                    "언급하지 마세요. save 표시, 분류 라벨, 괄호, "
                    "JSON은 출력하지 마세요."
                ),
            },
        ]
        yield from self._stream(messages)

    def _stream(
        self,
        messages: list[dict[str, str]],
    ) -> Iterator[str]:
        body = json.dumps(
            {
                "model": self._model,
                "messages": messages,
                "temperature": self._temperature,
                "top_p": self._top_p,
                "max_tokens": self._max_tokens,
                "stream": True,
            },
            ensure_ascii=False,
        ).encode("utf-8")
        request = urllib.request.Request(
            self._endpoint,
            data=body,
            headers={
                "Accept": "text/event-stream, application/json",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            response = urllib.request.urlopen(
                request,
                timeout=self._timeout_seconds,
            )
        except urllib.error.HTTPError as error:
            payload = error.read().decode("utf-8", errors="replace")
            raise LiteRTChatClientError(
                f"LiteRT-LM returned HTTP {error.code}: {payload}"
            ) from error
        except urllib.error.URLError as error:
            raise LiteRTChatClientError(
                f"Could not reach LiteRT-LM: {error.reason}"
            ) from error

        with response:
            content_type = response.headers.get_content_type()
            if content_type != "text/event-stream":
                payload = json.load(response)
                yield self._extract_message(payload)
                return

            for raw_line in response:
                line = raw_line.decode("utf-8").strip()
                if not line or line.startswith(":"):
                    continue
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    return
                try:
                    event = json.loads(data)
                except json.JSONDecodeError as error:
                    raise LiteRTChatClientError(
                        f"Invalid SSE JSON: {data}"
                    ) from error
                chunk = self._extract_delta(event)
                if chunk:
                    yield chunk

    @staticmethod
    def _extract_message(payload: dict[str, Any]) -> str:
        try:
            content = payload["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as error:
            raise LiteRTChatClientError(
                "Non-streaming response did not contain message content."
            ) from error
        if not isinstance(content, str):
            raise LiteRTChatClientError(
                "Non-streaming message content was not a string."
            )
        return content

    @staticmethod
    def _extract_delta(payload: dict[str, Any]) -> str:
        if "error" in payload:
            raise LiteRTChatClientError(
                f"LiteRT-LM streaming error: {payload['error']}"
            )
        choices = payload.get("choices")
        if not choices:
            return ""
        try:
            delta = choices[0].get("delta", {})
        except (AttributeError, TypeError) as error:
            raise LiteRTChatClientError(
                "Streaming choice was not an object."
            ) from error
        content = delta.get("content", "")
        if content is None:
            return ""
        if not isinstance(content, str):
            raise LiteRTChatClientError(
                "Streaming delta content was not a string."
            )
        return content
