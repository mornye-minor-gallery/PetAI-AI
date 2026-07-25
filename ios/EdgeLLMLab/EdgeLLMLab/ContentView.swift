
//
//  ContentView.swift
//  EdgeLLMLab
//
//  Created by 김김민석 on 7/24/26.
//

import SwiftUI
import EdgeLLM
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var runtime = LiteRTLMRuntime()
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

    var body: some View {
        TabView {
            chatView
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }

            EmbeddingTestView()
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
                        .disabled(isWorking || !isModelReady)

                        Button("Cancel", role: .destructive) {
                            cancelGeneration()
                        }
                        .disabled(!isWorking)

                        Button("Unload") {
                            unload()
                        }
                        .disabled(isWorking || !isModelReady)
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
                        systemPrompt: "You are a concise, helpful assistant."
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
        isWorking = true
        response = ""
        status = "Generating"
        generationStartedAt = Date()
        firstChunkReceivedAt = nil
        generationEndedAt = nil
        receivedCharacterCount = 0

        Task {
            do {
                let stream = try await runtime.generateStream(prompt: prompt)
                for try await chunk in stream {
                    if firstChunkReceivedAt == nil {
                        firstChunkReceivedAt = Date()
                        status = "Generating · Receiving tokens"
                    }
                    response += chunk
                    receivedCharacterCount += chunk.count
                }
                status = "Ready"
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
}

#Preview {
    ContentView()
}
