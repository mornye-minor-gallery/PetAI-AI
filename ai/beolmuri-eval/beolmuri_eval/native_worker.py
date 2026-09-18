"""Python 3.10-compatible LiteRT-LM transport; no persona/memory policy here.

The pinned Python conversation API omits max_output_tokens although the C API
supports it. Configure the native session explicitly instead of silently losing
the product's output cap. This narrow adapter is pinned to 0.13.1 and records
the mobile runtime difference; it is not an iPhone parity claim.
"""
import ctypes
import importlib.metadata
import json
import os
import sys
import time


class NativeRuntime:
    def __init__(self, model, cache_dir, max_num_tokens=4096):
        if type(max_num_tokens) is not int or not 1 <= max_num_tokens <= 2147483647:
            raise ValueError("max_num_tokens must be a positive Int32")
        self.max_num_tokens = max_num_tokens
        if importlib.metadata.version("litert-lm") != "0.13.1":
            raise RuntimeError("native adapter requires litert-lm 0.13.1")
        import litert_lm
        self.lm = litert_lm
        # The GPU weight-cache writer requires its directory to exist before
        # engine creation; unlike the CPU backend it does not create it.
        os.makedirs(cache_dir, exist_ok=True)
        started = time.monotonic()
        self.engine = litert_lm.Engine(model, backend=litert_lm.Backend.GPU(),
                                       cache_dir=cache_dir, max_num_tokens=max_num_tokens, enable_speculative_decoding=False)
        self.load_ms = (time.monotonic() - started) * 1000
        self.conversation = None
        self.reserved_output_tokens = None

    def _create_conversation(self, system_prompt, sampling, seed):
        from litert_lm.utils import _sampler_config_to_params
        from litert_lm.conversation import Conversation
        lib = self.engine._lib
        session = lib.litert_lm_session_config_create()
        config = lib.litert_lm_conversation_config_create()
        if not session or not config:
            raise RuntimeError("native config allocation failed")
        sampler = self.lm.SamplerConfig(temperature=sampling["temperature"], top_k=sampling["top_k"],
                                        top_p=sampling["top_p"], seed=seed)
        try:
            params = _sampler_config_to_params(sampler)
            lib.litert_lm_session_config_set_sampler_params(session, ctypes.byref(params))
            lib.litert_lm_session_config_set_max_output_tokens(session, sampling["max_output_tokens"])
            lib.litert_lm_conversation_config_set_session_config(config, session)
            messages = [{"role": "system", "content": system_prompt}]
            # Match the Swift adapter's systemMessage content representation.
            lib.litert_lm_conversation_config_set_system_message(
                config, json.dumps([{"type": "text", "text": system_prompt}]))
            lib.litert_lm_conversation_config_set_extra_context(config, json.dumps({"enable_thinking": sampling["thinking"]}))
            lib.litert_lm_conversation_config_set_filter_channel_content_from_kv_cache(
                config, sampling["filter_channel_content_from_kv_cache"])
            pointer = lib.litert_lm_conversation_create(self.engine._engine_ptr, config)
            if not pointer:
                raise RuntimeError("native conversation creation failed")
            return Conversation(lib, pointer, engine=self.engine, messages=messages,
                                             sampler_config=sampler,
                                             extra_context={"enable_thinking": sampling["thinking"]})
        finally:
            lib.litert_lm_conversation_config_delete(config)
            lib.litert_lm_session_config_delete(session)

    def start(self, system_prompt, sampling, seed, reserve_output=False):
        if self.conversation:
            self.conversation.close()
            self.conversation = None
        self.reserved_output_tokens = sampling['max_output_tokens'] if reserve_output else None
        self.conversation = self._create_conversation(system_prompt, sampling, seed)

    def count_tokens(self, text):
        if not isinstance(text, str) or "\0" in text:
            raise ValueError("tokenizer requires text without embedded nulls")
        return len(self.engine.tokenize(text))

    def _measure(self, conversation, message):
        cached = conversation.token_count
        rendered = conversation.render_message_to_string(message)
        if not rendered:
            raise RuntimeError("native prompt rendering returned empty text")
        if conversation.token_count != cached:
            raise RuntimeError("prompt inspection changed native token state")
        submitted = self.count_tokens(rendered)
        if type(cached) is not int or cached < 0:
            raise ValueError("invalid native cached token count")
        total = cached + submitted
        return {"input_tokens": total, "max_num_tokens": self.max_num_tokens,
                "available_output_tokens": self.max_num_tokens - total,
                "token_accounting": {"method": "native-kv-plus-rendered-message-tokenizer",
                                     "cached_tokens_before": cached, "submitted_tokens": submitted}}

    def measure_prompt(self, system_prompt, message, sampling):
        # Same template/thinking/filter configuration as generation. The probe
        # owns its session; an existing conversation and its retry KV are untouched.
        probe = self._create_conversation(system_prompt, sampling, seed=0)
        try:
            return self._measure(probe, message)
        finally:
            probe.close()

    def measure(self, message):
        if self.conversation is None:
            raise RuntimeError("conversation not started")
        result = self._measure(self.conversation, message)
        if result['available_output_tokens'] <= 0:
            raise ValueError(f"input {result['input_tokens']} leaves no output space in context capacity {self.max_num_tokens}")
        if (self.reserved_output_tokens is not None
                and result['available_output_tokens'] < self.reserved_output_tokens):
            raise ValueError(f"input {result['input_tokens']} + reserved output {self.reserved_output_tokens} exceeds {self.max_num_tokens}")
        return result

    def generate(self, message):
        measurement = self.measure(message)
        started = time.monotonic()
        first = None
        chunks = []
        for event in self.conversation.send_message_async(message):
            for item in event.get("content", []):
                if item.get("type") == "text" and item.get("text"):
                    if first is None:
                        first = (time.monotonic() - started) * 1000
                    chunks.append(item["text"])
        return {"status": "generated", "chunks": chunks,
                "first_output_ms": first, "elapsed_ms": (time.monotonic() - started) * 1000,
                **measurement, "output_tokens": None,
                "token_accounting": {**measurement["token_accounting"],
                                     "context_tokens_after": self.conversation.token_count},
                "telemetry_note": "input includes native template tokens; output/thermal/device-memory metrics unavailable"}

    def close(self):
        if self.conversation:
            self.conversation.close()
        self.engine.close()


def main():
    # Native libraries sometimes print to fd 1. Keep the JSONL channel separate.
    output = os.fdopen(os.dup(1), "w", buffering=1)
    os.dup2(2, 1)
    runtime = None
    try:
        for line in sys.stdin:
            request = {}
            try:
                request = json.loads(line)
                operation = request["operation"]
                if operation == "probe":
                    from litert_lm._ffi import _get_lib
                    _get_lib()
                    result = {"status": "available", "version": importlib.metadata.version("litert-lm"),
                              "backend": "gpu", "execution_verified": False,
                              "max_output_tokens_supported": True}
                elif operation == "load":
                    if runtime:
                        raise RuntimeError("engine already loaded")
                    runtime = NativeRuntime(request["model"], request["cache_dir"], request.get("max_num_tokens", 4096))
                    result = {"status": "loaded", "load_ms": runtime.load_ms}
                elif operation == "start":
                    runtime.start(request["system_prompt"], request["sampling"], request["seed"],
                                  reserve_output=request.get("reserve_output", False))
                    result = {"status": "started"}
                elif operation == "count_tokens":
                    result = {"status": "measured", "tokens": runtime.count_tokens(request["text"])}
                elif operation == "measure_prompt":
                    result = {"status": "measured", **runtime.measure_prompt(
                        request["system_prompt"], request["message"], request["sampling"])}
                elif operation == "measure":
                    result = {"status": "measured", **runtime.measure(request["message"])}
                elif operation == "generate":
                    result = runtime.generate(request["message"])
                else:
                    raise ValueError("unknown native operation")
            except Exception as error:
                result = {"status": "error", "error": type(error).__name__ + ": " + str(error)}
            result.update({"id": request.get("id"), "protocol_version": 1})
            output.write(json.dumps(result, ensure_ascii=False, allow_nan=False) + "\n")
    finally:
        if runtime:
            runtime.close()


if __name__ == "__main__":
    main()
