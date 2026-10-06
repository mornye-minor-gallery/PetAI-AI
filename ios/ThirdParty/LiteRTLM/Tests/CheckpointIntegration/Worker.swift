import Foundation
import EdgeLLM
import LiteRTLM
import Fixtures

typealias Request = DialogueModelInput
struct Result: Codable {
    let mode: String; let scenario: String; let output: String; let finish: String
    let inputTokens: Int; let seconds: Double; let firstVisibleSeconds: Double?
}
enum WorkerError: Error { case arguments, empty, busySaveAccepted, cancelNotObserved }

@main struct Worker {
    static func write<T: Encodable>(_ value: T, _ path: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    static func generate(_ session: CachedSession, _ request: Request, cancel: Bool = false,
                         busyPath: String? = nil) async throws -> (String, Double, Double?) {
        let messages = request.initialMessages.map { message -> Message in
            let role: Role
            switch message.role {
            case .system: role = .system
            case .user: role = .user
            case .assistant: role = .model
            }
            return Message(message.text, role: role)
        }
        try session.replaceInput(systemPrompt: nil, initialMessages: messages)
        let start = Date(); var first: Double?; var text = ""; var cancelled = false
        var gate = MemoryHeaderGate()
        do {
            for try await chunk in session.streamText(request.currentUserMessage, thinkingEnabled: false, maxOutputTokens: 64) {
                let visible = gate.consume(chunk).joined()
                if first == nil && !visible.isEmpty { first = Date().timeIntervalSince(start) }
                text += visible
                if cancel && !cancelled && !text.isEmpty {
                    if let busyPath {
                        do { try KVCheckpointStore(directory: URL(fileURLWithPath: busyPath)).save(identity: "integration-model-settings") { try session.transferState(reading: false, transfer: $0) }; throw WorkerError.busySaveAccepted }
                        catch CachedSessionError.busy {}
                    }
                    try session.cancel(); cancelled = true
                }
            }
        } catch {
            // The cancellation path is intentionally separate from successful completion.
            await session.waitUntilIdle()
            guard cancelled, session.latestCacheTrace()?.finishReason == "cancelled" else { throw error }
        }
        await session.waitUntilIdle()
        text = gate.finish().visibleText
        if cancel && session.latestCacheTrace()?.finishReason != "cancelled" { throw WorkerError.cancelNotObserved }
        return (text, Date().timeIntervalSince(start), first)
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { throw WorkerError.arguments }
        let mode = args[1], model = args[2], dir = args[3], scenario = args[4]
        let engine = Engine(engineConfig: try .init(modelPath: model, backend: .cpu(), maxNumTokens: 4096, cacheDir: ":nocache"))
        print("STAGE initialize", terminator: "\n"); fflush(stdout)
        try await engine.initialize()
        let session = try await engine.createCachedSession(sampler: .init(topK: 1, topP: 1, temperature: 0, seed: 42), maxOutputTokens: 64)
        print("STAGE ready"); fflush(stdout)
        let store = try KVCheckpointStore(directory: URL(fileURLWithPath: dir + "/cache"))
        let cache = store.fileURL.path
        if mode == "seed" {
            var context = try AppFixtures.context(count: scenario == "boundary" ? 19 : 2)
            let question = "엘레나야, 안녕! 한 문장으로 인사해줘."
            let prepared = try AppFixtures.prepare(context, id: "seed", message: question, dynamic: false)
            _ = try context.beginRequest(requestID: "seed", userMessage: question)
            let (reply, seconds, first) = try await generate(session, prepared.modelInput)
            guard !reply.isEmpty else { throw WorkerError.empty }
            try context.finishRequest(requestID: "seed", status: .completed, assistantMessage: reply)
            let saveStart = Date()
            try store.save(identity: "integration-model-settings") { try session.transferState(reading: false, transfer: $0) }
            print("STAGE saved seconds=\(Date().timeIntervalSince(saveStart))"); fflush(stdout)
            try write(Result(mode: mode, scenario: scenario, output: reply,
                finish: session.latestCacheTrace()?.finishReason ?? "unknown", inputTokens: session.latestCacheTrace()?.inputTokens ?? -1,
                seconds: seconds, firstVisibleSeconds: first), dir + "/seed.json")
            if scenario == "cancelled" || scenario == "failed" {
                let interrupted = "주말에 등산을 같이 가자. 코스를 길게 설명해줘."
                let prompt = try AppFixtures.prepare(context, id: "interrupted", message: interrupted, dynamic: false)
                _ = try context.beginRequest(requestID: "interrupted", userMessage: interrupted)
                if scenario == "cancelled" {
                    let (partial, _, _) = try await generate(session, prompt.modelInput,
                        cancel: true, busyPath: dir + "/must-not-exist.bin")
                    try context.appendAssistantText(requestID: "interrupted", text: partial)
                    try context.finishRequest(requestID: "interrupted", status: .cancelled)
                } else {
                    // Fixture of a failed turn; does not pretend to reproduce a native inference failure.
                    try context.finishRequest(requestID: "interrupted", status: .failed)
                }
            }
            try write(context.checkpoint(), dir + "/context.json")
            let restored = try RoutedPersonaSessionContext(checkpoint: context.checkpoint())
            let next = try AppFixtures.prepare(restored, id: "next", message: "우리 이제 뭘 하면 좋을까? 한 문장으로 말해줘.", dynamic: scenario == "dynamic")
            try write(next.modelInput, dir + "/request.json")
            let (warm, warmSeconds, warmFirst) = try await generate(session, next.modelInput)
            try write(Result(mode: "warm", scenario: scenario, output: warm,
                finish: session.latestCacheTrace()?.finishReason ?? "unknown", inputTokens: session.latestCacheTrace()?.inputTokens ?? -1,
                seconds: warmSeconds, firstVisibleSeconds: warmFirst), dir + "/warm.json")
        } else {
            let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/request.json")))
            if mode == "reference" {
                // Recreate exactly the last completed state without a file. Unlike
                // warm-after-cancel, this is a valid serialization control for old KV.
                let context = try AppFixtures.context(count: scenario == "boundary" ? 19 : 2)
                let seed = try AppFixtures.prepare(context, id: "seed", message: "엘레나야, 안녕! 한 문장으로 인사해줘.", dynamic: false)
                _ = try await generate(session, seed.modelInput)
            }
            if mode == "restore" {
                let start = Date(); try store.restore(identity: "integration-model-settings") { try session.transferState(reading: true, transfer: $0) }
                print("STAGE restored seconds=\(Date().timeIntervalSince(start))"); fflush(stdout)
            } else if ["corrupt", "incompatible", "truncated", "old-format"].contains(mode) {
                let damagedStore = try KVCheckpointStore(directory: URL(fileURLWithPath: dir + "/damaged-" + mode))
                let damaged = damagedStore.fileURL.path
                try FileManager.default.copyItem(atPath: cache, toPath: damaged)
                if mode == "corrupt" {
                    let file = try FileHandle(forUpdating: URL(fileURLWithPath: damaged))
                    let end = try file.seekToEnd()
                    try file.seek(toOffset: end - 1)
                    let byte = try file.read(upToCount: 1)![0] ^ 0xff
                    try file.seek(toOffset: end - 1)
                    try file.write(contentsOf: Data([byte]))
                    try file.close()
                } else if mode == "truncated" {
                    let file = try FileHandle(forUpdating: URL(fileURLWithPath: damaged))
                    let end = try file.seekToEnd()
                    try file.truncate(atOffset: end / 2)
                    try file.close()
                } else if mode == "old-format" {
                    let file = try FileHandle(forUpdating: URL(fileURLWithPath: damaged))
                    let headerSize = "PetAI-KV-v2\nintegration-model-settings\n".utf8.count
                    try file.seek(toOffset: UInt64(headerSize))
                    try file.write(contentsOf: Data([1, 0, 0, 0]))
                    try file.close()
                }
                do {
                    try damagedStore.restore(identity: mode == "incompatible" ? "wrong-model" : "integration-model-settings") { try session.transferState(reading: true, transfer: $0) }
                    throw WorkerError.busySaveAccepted
                } catch KVCheckpointError.invalidData {
                    guard mode != "old-format" else { throw KVCheckpointError.invalidData }
                } catch CachedSessionError.checkpoint(15) {
                    guard mode == "old-format" else { throw CachedSessionError.checkpoint(15) }
                }
                try FileManager.default.removeItem(atPath: damaged)
                print("STAGE rejected cache; recomputing with cleared executor")
            } else if mode != "cold" && mode != "reference" { throw WorkerError.arguments }
            let (reply, seconds, first) = try await generate(session, request)
            try write(Result(mode: mode, scenario: scenario, output: reply,
                finish: session.latestCacheTrace()?.finishReason ?? "unknown", inputTokens: session.latestCacheTrace()?.inputTokens ?? -1,
                seconds: seconds, firstVisibleSeconds: first), dir + "/\(mode).json")
        }
        print("STAGE finished"); fflush(stdout)
    }
}
