/// Memory-only input used by EdgeLLMLab, which owns its native conversation history.
/// Full persona dialogue should use DialoguePromptComposer.
public enum MemoryPromptBuilder {
    /// `tokenBudget` is the existing UTF-8 byte proxy, not an exact model token count.
    public static func build(
        userMessage: String,
        memories: [RetrievedMemoryObservation],
        tokenBudget: Int = SLMConfiguration.production.memory.promptByteBudget
    ) -> String {
        precondition(tokenBudget > 0)
        return DialogueMemoryContext.prepare(memories, byteBudget: tokenBudget)
            .render(currentMessage: userMessage)
    }
}
