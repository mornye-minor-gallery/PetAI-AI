import Foundation
#if canImport(EdgeLLM)
import EdgeLLM
#endif

public enum ChatRuntimeAssembly {
    public static func makeController(
        configuration: SLMConfiguration,
        platform: any ChatPlatformServices,
        cacheDirectory: URL,
        supportDirectory: URL,
        backend: ChatInferenceBackend = .cpu,
        engineIdentity: String = "cpu-kv2-prefix-cursor1",
        modelProfile: ChatModelProfile? = nil,
        eventSink: @escaping @Sendable (NativeChatEvent) -> Void,
        log: @escaping @Sendable (String) -> Void,
        toolRouterArtifacts: NativeToolRouterArtifactRegistry? = nil
    ) -> ChatSessionController {
        ChatSessionController(
            configuration: configuration,
            runtime: LiteRTLMRuntime(configuration: configuration, cacheDirectory: cacheDirectory,
                                    backend: backend, engineIdentity: engineIdentity, modelProfile: modelProfile),
            memory: MemoryService(supportDirectory: supportDirectory),
            platform: platform, eventSink: eventSink, log: log,
            toolRouterArtifacts: toolRouterArtifacts)
    }
}
