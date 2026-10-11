import CLiteRTLM

/// Bridges the existing CPU setting; both static and dynamic executors consume it.
enum EnginePrefillSettings {
    static func validate(_ size: Int?, isCPU: Bool) throws {
        guard let size else { return }
        guard isCPU, size > 0, size <= Int(Int32.max) else {
            throw LiteRTLMError.config(.invalidPrefillChunkSize)
        }
    }

    static func apply(_ size: Int?, to settings: OpaquePointer) {
        guard let size else { return }
        litert_lm_engine_settings_set_prefill_chunk_size(settings, Int32(size))
    }
}
