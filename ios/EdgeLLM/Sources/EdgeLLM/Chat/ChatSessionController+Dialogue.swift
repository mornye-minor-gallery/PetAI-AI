import Foundation

// Prompt preparation is separate from Unity event delivery and tool execution.
extension ChatSessionController {
    func configuredDialogue() -> (prompts: RoutedPersonaPromptSet, policy: DialoguePromptPolicy) {
        if let prompts = routedPersonaPrompts { return (prompts, dialoguePromptPolicy) }
        // Disabling persona changes fixed instructions, not ownership of history
        // or token limits. Both development modes use the same composition path.
        var persona = dialoguePromptPolicy.persona
        persona.includePersona = false
        persona.enforceCharacterName = false
        return (.init(core: ""), .init(persona: persona, memoryByteBudget: dialoguePromptPolicy.memoryByteBudget))
    }

    func prepareRoutedPersonaGeneration(
        requestID: String,
        userMessage: String,
        recalledMemories: [RetrievedMemoryObservation],
        userProfileContext: UserProfileContext,
        thinkingEnabled: Bool,
        session: DialogueSessionSnapshot,
        worldContext: WorldInfoContext = .init()
    ) async throws -> (prompt: String, worldInfo: WorldInfoTransaction?) {
        let (prompts, policy) = configuredDialogue()

        let scene = PersonaSceneRoute.general

        var reactionMatch: ReactionFrameIndex.Match?
        if let index = dialogueRetrieval?.index, let gate = dialogueRetrieval?.queryGate {
            let started = ProcessInfo.processInfo.systemUptime
            let currentVector = try await memoryService.embedWorldInfoQuery(userMessage)
            let currentEmbeddingMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
            let identity = try await memoryService.searchEmbeddingIdentity()
            let gateStarted = ProcessInfo.processInfo.systemUptime
            let messageCount = try gate.select(current: userMessage, embedding: currentVector,
                                               embeddingIdentity: identity)
            let gateMS = (ProcessInfo.processInfo.systemUptime - gateStarted) * 1000
            let query = ReactionFrameIndex.query(history: session.history.map(\.text), current: userMessage,
                                                 messageCount: messageCount)
            let vector = query == userMessage ? currentVector : try await memoryService.embedWorldInfoQuery(query)
            let totalMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
            let match = try index.search(query: vector, embeddingIdentity: identity)
            reactionMatch = match
            logger.notice("Reaction frame id=\(match.frame.id) queryMessages=\(min(messageCount.rawValue, session.history.count + 1)) embeddingCalls=\(query == userMessage ? 1 : 2) score=\(match.score) currentEmbeddingMS=\(currentEmbeddingMS) gateMS=\(gateMS) retrievalMS=\(totalMS) searchMS=\(match.searchMilliseconds)")
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
            input: DialoguePromptInput(persona: prompts, activeCard: nil,
                profile: userProfileContext, history: session.history,
                memories: recalledMemories, currentMessage: userMessage,
                session: session, authorsNote: slmConfiguration.authorsNote, worldInfo: worldInfo, worldInfoContext: worldContext, exampleDialogue: platform.personaEnabled ? dialogueContent?.exampleDialogue ?? "" : "", authoredText: authoredText,
                reactionEntryID: reactionMatch?.frame.entry.id,
                topicGuidance: session.topicContext?.promptText),
            policy: policy,
            thinkingEnabled: thinkingEnabled
        )
        lastDialogueTemplate = prepared.contextTemplate
        lastDialogueThinking = thinkingEnabled
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

}
