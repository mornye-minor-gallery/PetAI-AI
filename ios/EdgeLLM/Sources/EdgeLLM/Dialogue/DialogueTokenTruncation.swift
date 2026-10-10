import Foundation

public enum DialogueTokenTruncation {
    /// Character boundaries protect Unicode while the model tokenizer decides size.
    /// A final measurement is required because token counts are not character counts.
    public static func prefix(_ text: String, maximumTokens: Int,
                              measurer: any DialogueTokenMeasuring) async throws -> String {
        guard maximumTokens >= 0 else { throw DialogueTokenBudgetError.invalidBudget }
        if maximumTokens == 0 { return "" }
        let original = try await measurer.countTokens(text)
        guard original >= 0 else { throw DialogueTokenBudgetError.invalidMeasurement }
        if original <= maximumTokens { return text }
        let characters = Array(text)
        var lower = 0, upper = characters.count
        var accepted = ""
        // Token merges can make the count locally non-monotonic. We retain a
        // measured fitting prefix rather than assuming an exact token cut point.
        while lower < upper {
            try Task.checkCancellation()
            let middle = lower + (upper - lower + 1) / 2
            let candidate = String(characters.prefix(middle))
            let count = try await measurer.countTokens(candidate)
            guard count >= 0 else { throw DialogueTokenBudgetError.invalidMeasurement }
            if count <= maximumTokens { accepted = candidate; lower = middle }
            else { upper = middle - 1 }
        }
        let count = try await measurer.countTokens(accepted)
        guard count >= 0, count <= maximumTokens else { throw DialogueTokenBudgetError.invalidMeasurement }
        return accepted
    }
}
