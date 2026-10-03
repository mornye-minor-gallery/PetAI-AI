import Foundation

// Prompt preparation is separate from Unity event delivery and tool execution.
extension ChatSessionController {
    func prepareRoutedPersonaGeneration(
        requestID: String,
        userMessage: String,
        recalledMemories: [RetrievedMemoryObservation],
        userProfileContext: UserProfileContext,
        thinkingEnabled: Bool,
        session: DialogueSessionSnapshot,
        worldContext: WorldInfoContext = .init()
    ) async throws -> (prompt: String, worldInfo: WorldInfoTransaction?) {
        guard let prompts = routedPersonaPrompts else {
            return (userProfileContext.promptSection()
                + "\n\n" + MemoryPromptBuilder.build(
                    userMessage: userMessage, memories: recalledMemories,
                    tokenBudget: dialoguePromptPolicy.memoryByteBudget), nil)
        }

        let scene = try await routeSceneWithEmbedding(userMessage)

        var reactionMatch: ReactionFrameIndex.Match?
        if let index = dialogueRetrieval?.index {
            let query = ReactionFrameIndex.query(history: session.history.map(\.text), current: userMessage)
            let started = ProcessInfo.processInfo.systemUptime
            let vector = try await memoryService.embedWorldInfoQuery(query)
            let embeddingMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
            let match = try index.search(query: vector, embeddingIdentity: await memoryService.searchEmbeddingIdentity())
            reactionMatch = match
            logger.notice("Reaction frame id=\(match.frame.id) score=\(match.score) embeddingMS=\(embeddingMS) searchMS=\(match.searchMilliseconds)")
        }
        let worldInfo = dialogueRetrieval?.worldInfo(base: slmConfiguration.worldInfo, match: reactionMatch) ?? slmConfiguration.worldInfo
        var worldContext = worldContext
        if let settings = worldInfo, let vector = settings.rules.vector {
            let entries = try (settings.library?.entries(character: userProfileContext.characterName) ?? []) + settings.entries
            let matches = try await memoryService.searchWorldInfo(entries: entries,
                newestMessages: [userMessage] + session.history.reversed().map(\.text), settings: vector)
            worldContext.vectorMatches = matches.map(\.id)
        }
        var authoredText = slmConfiguration.authoredText ?? .init()
        if authoredText.runtime["nowMilliseconds"] == nil {
            authoredText.runtime["nowMilliseconds"] = .number(Date().timeIntervalSince1970 * 1000)
            authoredText.runtime["utcOffsetMinutes"] = .number(Double(TimeZone.current.secondsFromGMT() / 60))
        }
        authoredText.runtime["isMobile"] = .bool(true)
        let prepared = try await runtime.prepareDialogue(
            input: DialoguePromptInput(persona: prompts, activeCard: prompts.card(scene: scene),
                profile: userProfileContext, history: session.history,
                memories: recalledMemories, currentMessage: userMessage,
                session: session, authorsNote: slmConfiguration.authorsNote, worldInfo: worldInfo, worldInfoContext: worldContext, exampleDialogue: dialogueContent?.exampleDialogue ?? "", authoredText: authoredText),
            policy: dialoguePromptPolicy,
            thinkingEnabled: thinkingEnabled
        )
        diagnostics?.prepared(requestID, scene, recalledMemories.count, prepared)
        if let world = prepared.trace.worldInfo {
            let selected = world.entries.filter { $0.reason == .selected }.count
            let inserted = world.entries.filter { $0.delivery == .inserted }.count
            logger.notice("World Info selected=\(selected) inserted=\(inserted) budget=\(world.tokenBudget) overflowed=\(world.overflowed)")
        }
        if let note = prepared.trace.authorsNote {
            logger.notice("Author note state=\(note.state.rawValue) userMessage=\(note.userMessageNumber) position=\(note.position.rawValue) depth=\(note.depth)")
        }
        if let budget = prepared.trace.tokenBudget {
            let data = try JSONEncoder().encode(budget)
            let record = String(decoding: data, as: UTF8.self)
            logger.notice("Dialogue token budget \(record)")
        }
        logger.notice(
            "Routed persona scene selected scene=\(scene.rawValue)"
        )
        logger.debug(
            "Dialogue composition placement=\(prepared.trace.nameRulePlacement.rawValue) historyMessages=\(prepared.trace.historyMessages) insertedMemories=\(prepared.trace.insertedMemoryCount) memoryBytes=\(prepared.trace.insertedMemoryBytes) userBytes=\(prepared.trace.userBytes)"
        )
        return (prepared.modelInput.currentUserMessage, prepared.worldInfoTransaction)
    }

    func routeSceneWithEmbedding(
        _ userMessage: String
    ) async throws -> PersonaSceneRoute {
        guard let router = embeddingSceneRouter else {
            logger.error(
                "Embedding scene router is unavailable; using GENERAL"
            )
            return .general
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        diagnostics?.mark("scene.route.begin", [:])
        do {
            let query = try await memoryService.embedClassification(
                userMessage
            )
            let result = try router.route(query)
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            logger.notice(
                "Embedding scene selected scene=\(result.scene.rawValue) reason=\(result.reason.rawValue) score=\(result.score) threshold=\(result.threshold) margin=\(result.normalizedMargin) accepted=\(result.acceptedRouteCount) elapsed=\(String(describing: elapsed))"
            )
            diagnostics?.mark("scene.route.exit", [
                "scene": result.scene.rawValue,
                "status": "selected"
            ])
            return result.scene
        } catch is CancellationError {
            if cancelRequested {
                throw RuntimeError.generationCancelled
            }
            logger.error(
                "Embedding scene routing was cancelled unexpectedly; using GENERAL"
            )
            diagnostics?.mark("scene.route.exit", [
                "scene": PersonaSceneRoute.general.rawValue,
                "status": "cancelled_fallback"
            ])
            return .general
        } catch {
            logger.error(
                "Embedding scene routing failed; using GENERAL error=\(error.localizedDescription)"
            )
            diagnostics?.mark("scene.route.exit", [
                "scene": PersonaSceneRoute.general.rawValue,
                "status": "error_fallback"
            ])
            return .general
        }
    }

}
