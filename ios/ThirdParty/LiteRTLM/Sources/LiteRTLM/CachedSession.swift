import Foundation
import CLiteRTLM

public struct CachedSessionTrace: Sendable {
    public let sessionID: String
    public let inputTokens: Int
    /// Input/input token overlap only. Not the measured native KV hit count.
    public let matchingInputPrefixTokens: Int
    public var finishReason: String? = nil
}

/// Text-only full-prompt replacement using the existing Session C API.
/// Rewind moves the cursor, not the KV buffers. In v0.17.1 CPU,
/// ResourceManager::LockedLlmExecutor::Prefill removes matching tokens before
/// calling the executor. Always submit the FULL input; even an identical or
/// shorter request must rewind so the previous generated suffix is discarded.
/// This is deliberately not a reimplementation of native prefix matching.
public final class CachedSession: TextSession, @unchecked Sendable {
    let handle: OpaquePointer
    private let engine: Engine // Engine outlives its native session.
    private let maxOutputTokens: Int
    private let lifetime = NativeStreamLifetime()
    private let lock = NSLock()
    private var systemPrompt: String?
    private var history: [Message] = [] // Only retries within the current request.
    private var prefix = InputPrefixTrace()
    private var trace: CachedSessionTrace?
    public let id = UUID().uuidString

    init(engine: Engine, engineHandle: OpaquePointer, sampler: SamplerConfig, maxOutputTokens: Int) throws {
        guard maxOutputTokens > 0, let limit = Int32(exactly: maxOutputTokens),
              let topK = Int32(exactly: sampler.topK), let seed = Int32(exactly: sampler.seed),
              let config = litert_lm_session_config_create() else { throw CachedSessionError.configuration }
        defer { litert_lm_session_config_delete(config) }
        guard let params = litert_lm_sampler_params_create(kLiteRtLmSamplerTypeTopP) else {
            throw CachedSessionError.configuration
        }
        defer { litert_lm_sampler_params_delete(params) }
        litert_lm_sampler_params_set_top_k(params, topK)
        litert_lm_sampler_params_set_top_p(params, sampler.topP)
        litert_lm_sampler_params_set_temperature(params, sampler.temperature)
        litert_lm_sampler_params_set_seed(params, seed)
        litert_lm_session_config_set_sampler_params(config, params)
        litert_lm_session_config_set_max_output_tokens(config, limit)
        litert_lm_session_config_set_apply_prompt_template(config, false)
        guard let session = litert_lm_engine_create_session(engineHandle, config) else {
            throw CachedSessionError.configuration
        }
        self.handle = session; self.engine = engine; self.maxOutputTokens = maxOutputTokens
#if RESOURCE_BENCH
        RuntimeResourceTrace.mark("session.created", ["session_id": id])
#endif
    }

    deinit {
#if RESOURCE_BENCH
        RuntimeResourceTrace.mark("session.delete.begin", ["session_id": id])
        defer { RuntimeResourceTrace.mark("session.delete.exit", ["session_id": id]) }
#endif
        litert_lm_session_delete(handle)
    }

    /// Prepare a new complete app turn. Do not reset native KV or carry old
    /// dynamic messages forward: the app supplies its authoritative history.
    public func replaceInput(systemPrompt: String?) throws {
        try lock.withLock {
            guard !lifetime.isActive else { throw CachedSessionError.busy }
            self.systemPrompt = systemPrompt; history = []; trace = nil
        }
    }

    public func latestCacheTrace() -> CachedSessionTrace? { lock.withLock { trace } }
    public func waitUntilIdle() async { await lifetime.waitUntilFinished() }
    public func cancel() throws {
        lifetime.requestCancellation()
        litert_lm_session_cancel_process(handle)
    }
    public func getTokenCount() throws -> Int { throw CachedSessionError.tokenCountUnavailable }

    func render(_ prompt: String, thinkingEnabled: Bool) async throws -> String {
        let (system, messages) = lock.withLock { (systemPrompt, history) }
        return try await engine.renderTextRequest(systemPrompt: system, history: messages,
            userPrompt: prompt, thinkingEnabled: thinkingEnabled)
    }

    public func measureInput(_ prompt: String, thinkingEnabled: Bool) async throws -> Int {
        let rendered = try await render(prompt, thinkingEnabled: thinkingEnabled)
        return try await engine.countTokens(rendered)
    }

    public func streamText(_ prompt: String, thinkingEnabled: Bool, maxOutputTokens: Int) -> AsyncThrowingStream<String, Error> {
        guard maxOutputTokens == self.maxOutputTokens else {
            return AsyncThrowingStream { $0.finish(throwing: CachedSessionError.configuration) }
        }
        guard lock.withLock({ lifetime.tryBegin() }) else {
            return AsyncThrowingStream { $0.finish(throwing: CachedSessionError.busy) }
        }
        return AsyncThrowingStream { continuation in
            // Retains the native session through setup AND the terminal callback.
            Task {
                do {
                    let rendered = try await self.render(prompt, thinkingEnabled: thinkingEnabled)
                    guard rendered.contains("<|turn>model") else { throw CachedSessionError.unsupportedTemplate }
                    let bos = try await self.engine.startTokenText()
                    let nativeText = !bos.isEmpty && rendered.hasPrefix(bos) ? String(rendered.dropFirst(bos.count)) : rendered
                    let tokens = try await self.engine.tokenIDs(bos + nativeText)
                    self.lock.withLock {
                        self.trace = .init(sessionID: self.id, inputTokens: tokens.count,
                            matchingInputPrefixTokens: self.prefix.prepare(tokens))
                    }
                    let context = CachedStreamContext(owner: self, continuation: continuation,
                        prompt: prompt, tokens: tokens, prefill: rendered)
                    try self.startNative(nativeText, context: context)
                } catch {
                    self.complete(prompt: prompt, output: "", tokens: [], success: false)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func startNative(_ text: String, context: CachedStreamContext) throws {
        guard !lifetime.isCancellationRequested else { throw CancellationError() }
        guard litert_lm_session_rewind_to_step(handle, 0) == 0 else { throw CachedSessionError.rewind }
        guard !lifetime.isCancellationRequested else { throw CancellationError() }
        let input = text.withCString { litert_lm_input_data_create(kLiteRtLmInputDataTypeText, $0, text.utf8.count) }
        guard let input else { throw CachedSessionError.input }
        defer { litert_lm_input_data_delete(input) }
        let opaque = Unmanaged.passRetained(context).toOpaque()
        var pointer: OpaquePointer? = input
#if RESOURCE_BENCH
        RuntimeResourceTrace.mark("session.submit.begin", [
            "session_id": id,
            "input_tokens": String(context.tokens.count),
            "matching_input_prefix_tokens": String(latestCacheTrace()?.matchingInputPrefixTokens ?? 0)
        ])
#endif
        let status = litert_lm_session_generate_content_stream(handle, &pointer, 1, cachedStreamCallback, opaque)
        if status != 0 {
            Unmanaged<CachedStreamContext>.fromOpaque(opaque).release()
#if RESOURCE_BENCH
            RuntimeResourceTrace.mark("session.submit.exit", ["session_id": id, "status": String(status)])
#endif
            throw CachedSessionError.start(Int(status))
        }
        // Cancellation may race admission. Reissue after submission; native cancel
        // is not evidence of completion, and the callback still owns the session.
        if lifetime.isCancellationRequested { litert_lm_session_cancel_process(handle) }
    }

    fileprivate func complete(prompt: String, output: String, tokens: [Int32], success: Bool, finishReason: String = "stop") {
        lock.withLock {
            trace?.finishReason = lifetime.isCancellationRequested ? "cancelled" : (success ? finishReason : "error")
            if success && !lifetime.isCancellationRequested {
                prefix.commit(tokens)
                history += [Message(prompt), Message(output, role: .model)]
            } else { prefix.invalidate() }
        }
#if RESOURCE_BENCH
        RuntimeResourceTrace.mark("session.submit.exit", [
            "session_id": id,
            "status": success ? "0" : "error",
            "finish_reason": finishReason
        ])
#endif
        lifetime.finish()
    }
}

public enum CachedSessionError: Error, LocalizedError {
    case configuration, busy, rewind, input, start(Int), native(String)
    case tokenCountUnavailable, unsupportedTemplate, unsupportedBackend
    public var errorDescription: String? {
        switch self {
        case .configuration: return "Invalid cached-session configuration or native session creation failed."
        case .busy: return "Cached session still has an active native operation."
        case .rewind: return "Native session rewind failed."
        case .input: return "Native text input allocation failed."
        case .start(let code): return "Native cached stream admission failed (\(code))."
        case .native(let message): return message
        case .tokenCountUnavailable: return "Session C API does not expose the current KV token count."
        case .unsupportedBackend: return "Cached Session C adapter currently supports the CPU backend."
        case .unsupportedTemplate: return "Cached text output framing currently requires the Gemma 4 template."
        }
    }
}

private final class CachedStreamContext {
    let owner: CachedSession
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    let prompt: String
    let tokens: [Int32]
    var filter: GemmaChannelFilter
    var output = ""
    init(owner: CachedSession, continuation: AsyncThrowingStream<String, Error>.Continuation,
         prompt: String, tokens: [Int32], prefill: String) {
        self.owner = owner; self.continuation = continuation; self.prompt = prompt; self.tokens = tokens
        filter = .init(prefill: prefill)
    }
    func yield(_ text: String) {
        guard !text.isEmpty else { return }
        output += text; continuation.yield(text)
    }
}

private func cachedStreamCallback(_ data: UnsafeMutableRawPointer?, _ chunk: OpaquePointer?) {
    guard let data else { return }
    let context = Unmanaged<CachedStreamContext>.fromOpaque(data).takeUnretainedValue()
    let error = litert_lm_stream_chunk_get_error(chunk).map { String(cString: $0) }
    // Match Conversation's default return_error_on_max_tokens_reached=false:
    // reaching the generation limit returns the available response, including
    // an empty visible response for a thought-only result. Other failures remain errors.
    let reachedLimit = error == "Max number of tokens reached."
    if let error, !reachedLimit {
        context.owner.complete(prompt: context.prompt, output: "", tokens: [], success: false)
        context.continuation.finish(throwing: CachedSessionError.native(error))
        Unmanaged<CachedStreamContext>.fromOpaque(data).release()
        return
    }
    if let text = litert_lm_stream_chunk_get_text(chunk) { context.yield(context.filter.append(String(cString: text))) }
    if litert_lm_stream_chunk_is_final(chunk) || reachedLimit {
        context.yield(context.filter.finish())
        context.owner.complete(prompt: context.prompt, output: context.output, tokens: context.tokens, success: true, finishReason: reachedLimit ? "token_limit" : "stop")
        context.continuation.finish()
        Unmanaged<CachedStreamContext>.fromOpaque(data).release()
    }
}
