
//
//  ContentView.swift
//  EdgeLLMLab
//
//  Created by 김김민석 on 7/24/26.
//

import SwiftUI
import EdgeLLM
import OSLog
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var runtime = LiteRTLMRuntime()
    @State private var memoryService = MemoryService()
    @State private var memoryCommitGuard =
        MemoryTaggedChatCommitGuard()
    @State private var embeddingAssetStore = EmbeddingAssetStore()
    @State private var isModelImporterPresented = false
    @State private var selectedModelURL: URL?
    @State private var prompt = "Hello! Introduce yourself briefly."
    @State private var response = ""
    @State private var status = "Model required"
    @State private var isWorking = false
    @State private var isModelReady = false
    @State private var generationStartedAt: Date?
    @State private var firstChunkReceivedAt: Date?
    @State private var generationEndedAt: Date?
    @State private var receivedCharacterCount = 0
    @State private var requiresAppRestart = false
    @State private var memoryStatus = "Not prepared"
    @State private var memoryWriteStatus = "Not run"
    @State private var memoryGateStatus = "Not run"
    @State private var retrievedMemories: [RetrievedMemoryObservation] = []
    @State private var memorySessionID = UUID().uuidString.lowercased()

    private let memoryScope = MemoryScope(
        userID: "local-user",
        characterID: "emu"
    )
    private let memoryLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EdgeLLMLab",
        category: "ChatMemory"
    )

    var body: some View {
        TabView {
            chatView
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }

            EmbeddingTestView(memoryService: memoryService)
                .tabItem {
                    Label("Embedding", systemImage: "point.3.connected.trianglepath.dotted")
                }
        }
    }

    private var chatView: some View {
        NavigationStack {
            Form {
                Section("Runtime") {
                    LabeledContent("Status", value: status)
                    if generationStartedAt != nil {
                        TimelineView(.periodic(from: .now, by: 0.25)) {
                            context in
                            LabeledContent(
                                "Generation",
                                value: generationDetail(at: context.date)
                            )
                        }
                    }
                    LabeledContent(
                        "Model",
                        value: selectedModelURL?.lastPathComponent ?? "Not selected"
                    )

                    Button("Choose and load .litertlm model") {
                        isModelImporterPresented = true
                    }
                    .disabled(isWorking || requiresAppRestart)

                    if requiresAppRestart {
                        Text(
                            "LiteRT-LM did not stop cleanly. Fully close and reopen this app before loading or generating again."
                        )
                        .foregroundStyle(.red)
                    }
                }

                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 100)

                    HStack {
                        Button("Generate") {
                            generate()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || !isModelReady)

                        Button("Cancel", role: .destructive) {
                            cancelGeneration()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!isWorking)

                        Button("Unload") {
                            unload()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isWorking || !isModelReady)
                    }
                }

                Section("Memory") {
                    LabeledContent("Status", value: memoryStatus)
                    LabeledContent(
                        "Retrieved",
                        value: "\(retrievedMemories.count)"
                    )
                    LabeledContent("Last gate", value: memoryGateStatus)
                    LabeledContent("Last write", value: memoryWriteStatus)

                    ForEach(
                        retrievedMemories,
                        id: \.observation.id
                    ) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                "#\(result.rank) · \(formattedMemoryScore(result.score))"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            Text(result.observation.rawText)
                        }
                    }
                }

                Section("Response") {
                    Text(response.isEmpty ? "No response yet." : response)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("EdgeLLM Lab")
        }
        .fileImporter(
            isPresented: $isModelImporterPresented,
            allowedContentTypes: [modelContentType],
            allowsMultipleSelection: false
        ) { result in
            handleModelSelection(result)
        }
    }

    private var modelContentType: UTType {
        UTType(filenameExtension: "litertlm") ?? .data
    }

    private func handleModelSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let URLs):
            guard let modelURL = URLs.first else {
                status = "No model selected"
                return
            }
            selectedModelURL = modelURL
            isModelReady = false
            load(modelURL)
        case .failure(let error):
            status = error.localizedDescription
        }
    }

    private func load(_ modelURL: URL) {
        isWorking = true
        response = ""
        status = "Preparing model"
        clearGenerationDiagnostics()

        Task {
            do {
                try await runtime.prepare(modelURL: modelURL)
                try await runtime.startConversation(
                    configuration: ConversationConfiguration(
                        systemPrompt: MemoryTaggedChatPrompt.wrappedAxesV1,
                        temperature: 0,
                        topK: 40,
                        topP: 1
                    )
                )
                status = "Ready"
                isModelReady = true
            } catch {
                status = error.localizedDescription
                isModelReady = false
            }
            isWorking = false
        }
    }

    private func generate() {
        let userMessage = prompt
        let sourceMessageID = UUID().uuidString.lowercased()
        isWorking = true
        response = ""
        status = "Generating"
        memoryWriteStatus = "Not run"
        memoryGateStatus = "Not run"
        retrievedMemories = []
        generationStartedAt = Date()
        firstChunkReceivedAt = nil
        generationEndedAt = nil
        receivedCharacterCount = 0

        Task {
            let memoryReady = await prepareMemoryIfNeeded()
            let memories = memoryReady
                ? await recallMemories(for: userMessage)
                : []
            let generationPrompt = MemoryPromptBuilder.build(
                userMessage: userMessage,
                memories: memories
            )

            do {
                let outcome = try await MemoryTaggedChatProcessor.run(
                    primaryStream: {
                        try await self.runtime.generateStream(
                            prompt: generationPrompt
                        )
                    },
                    retryStream: {
                        try await self.runtime.generateStream(
                            prompt: MemoryTaggedChatPrompt.answerOnlyRetry
                        )
                    },
                    receiveVisibleText: { text in
                        self.receiveVisibleChunk(text)
                    }
                )
                memoryGateStatus = formattedHeader(outcome.primary)

                if !outcome.hasVisibleResponse {
                    status = "No response body · try again"
                    memoryWriteStatus = "Skipped · no response body"
                } else if memoryReady,
                    let decision = await memoryCommitGuard.claim(
                        requestID: sourceMessageID,
                        outcome: outcome
                    )
                {
                    status = "Ready"
                    await rememberUserMessage(
                        userMessage,
                        sourceMessageID: sourceMessageID,
                        label: decision
                    )
                } else {
                    status = "Ready"
                    memoryWriteStatus =
                        outcome.primary.decision == MemoryGateLabel.none
                        ? "Skipped · Gemma chose N"
                        : "Skipped · unresolved header"
                }
            } catch {
                status = error.localizedDescription
                if let runtimeError = error as? RuntimeError,
                    case .cancellationTimedOut = runtimeError
                {
                    requiresAppRestart = true
                }
                if case .failed = await runtime.state {
                    isModelReady = false
                }
            }
            generationEndedAt = Date()
            isWorking = false
        }
    }

    private func prepareMemoryIfNeeded() async -> Bool {
        if await memoryService.isPrepared() {
            memoryStatus = "Ready"
            return true
        }

        memoryStatus = "Preparing EmbeddingGemma"
        do {
            let assets = try await embeddingAssetStore.installedAssets()
            guard
                let modelURL = assets.modelURL,
                let tokenizerURL = assets.tokenizerURL
            else {
                memoryStatus = "Embedding assets required · chat continues"
                return false
            }

            try await memoryService.prepareIfNeeded(
                modelURL: modelURL,
                tokenizerURL: tokenizerURL
            )
            memoryStatus = "Ready"
            return true
        } catch {
            memoryStatus = "Unavailable · chat continues without memory"
            memoryLogger.error(
                "Memory preparation failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func recallMemories(
        for userMessage: String
    ) async -> [RetrievedMemoryObservation] {
        do {
            let results = try await memoryService.recall(
                MemorySearchRequest(
                    scope: memoryScope,
                    query: userMessage,
                    topK: 3
                )
            )
            retrievedMemories = results
            memoryStatus = "Ready · \(results.count) retrieved"
            return results
        } catch {
            memoryStatus = "Search failed · chat continues"
            memoryLogger.error(
                "Memory recall failed: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private func rememberUserMessage(
        _ userMessage: String,
        sourceMessageID: String,
        label: MemoryGateLabel
    ) async {
        do {
            let result = try await memoryService.remember(
                MemoryWriteRequest(
                    sourceMessageID: sourceMessageID,
                    sessionID: memorySessionID,
                    scope: memoryScope,
                    rawText: userMessage
                ),
                decision: .taggedChat(label)
            )
            memoryGateStatus = formattedGate(result.gate)
            switch result.status {
            case .indexed:
                let labels = result.observation?.labels
                    .map(\.rawValue)
                    .joined(separator: ", ") ?? "unknown"
                memoryWriteStatus = "Stored · \(labels)"
            case .indexedUnlabeled:
                memoryWriteStatus = "Stored · unlabeled"
            case .skippedHardIgnore:
                memoryWriteStatus = "Skipped · hard ignore"
            case .skippedNoMemorySignal:
                memoryWriteStatus = "Skipped · no memory signal"
            case .ignoredEmpty:
                memoryWriteStatus = "Ignored · empty"
            }
        } catch {
            memoryWriteStatus = "Save failed · response kept"
            memoryLogger.error(
                "Memory save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func receiveVisibleChunk(_ chunk: String) {
        guard !chunk.isEmpty else {
            return
        }
        if firstChunkReceivedAt == nil {
            firstChunkReceivedAt = Date()
            status = "Generating · Receiving tokens"
        }
        response += chunk
        receivedCharacterCount += chunk.count
    }

    private func cancelGeneration() {
        status = "Cancelling"

        Task {
            await runtime.cancel()
        }
    }

    private func unload() {
        Task {
            do {
                try await runtime.unload()

                guard await runtime.state == .modelRequired else {
                    status = "Unload did not complete"
                    return
                }

                selectedModelURL = nil
                isModelReady = false
                response = ""
                status = "Model required"
                isWorking = false
                clearGenerationDiagnostics()
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func generationDetail(at now: Date) -> String {
        guard let startedAt = generationStartedAt else {
            return "Not started"
        }

        let effectiveEnd = generationEndedAt ?? now
        let elapsed = max(0, effectiveEnd.timeIntervalSince(startedAt))

        guard let firstChunkAt = firstChunkReceivedAt else {
            let phase = generationEndedAt == nil
                ? "waiting for first token"
                : "no token received"
            return "\(elapsed.formatted(.number.precision(.fractionLength(1))))s · \(phase)"
        }

        let timeToFirstToken = max(
            0,
            firstChunkAt.timeIntervalSince(startedAt)
        )
        return [
            "\(elapsed.formatted(.number.precision(.fractionLength(1))))s",
            "first token \(timeToFirstToken.formatted(.number.precision(.fractionLength(1))))s",
            "\(receivedCharacterCount) chars",
        ].joined(separator: " · ")
    }

    private func clearGenerationDiagnostics() {
        generationStartedAt = nil
        firstChunkReceivedAt = nil
        generationEndedAt = nil
        receivedCharacterCount = 0
    }

    private func formattedMemoryScore(_ score: Float) -> String {
        score.formatted(
            .number.precision(.fractionLength(4))
        )
    }

    private func formattedGate(
        _ gate: MemoryGateDecision?
    ) -> String {
        guard let gate else {
            return "Not run"
        }
        let preference = gate.preferenceScore.map(formattedMemoryScore)
            ?? "n/a"
        let event = gate.eventScore.map(formattedMemoryScore)
            ?? "n/a"
        return
            "\(gate.label.rawValue) · pref \(preference) · event \(event)"
    }

    private func formattedHeader(
        _ result: MemoryHeaderGateResult
    ) -> String {
        let decision = result.decision?.rawValue ?? "unresolved"
        return "\(decision) · \(result.syntax.rawValue)"
    }
}

#Preview {
    ContentView()
}
