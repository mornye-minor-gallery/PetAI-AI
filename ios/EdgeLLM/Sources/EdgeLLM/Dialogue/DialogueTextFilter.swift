/// Display policy for generated character dialogue, shared by the app and evaluation.
/// Filters Unicode scalars so filtering individual stream chunks is identical to
/// filtering their concatenation, even across decomposed Hangul or emoji sequences.
/// This is character removal, not normalization or a word/style rewrite. For example,
/// a keycap emoji loses its combining marks but retains its allowed ASCII digit.
public struct DialogueTextFilter: Sendable {
    public init() {}

    private static let punctuation: Set<Unicode.Scalar> = Set(
        ".,!?;:'\"()[]-~…=+/%".unicodeScalars
    )

    public func apply(to text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter(Self.allows)))
    }

    private static func allows(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D, 0x20, // tab, line breaks, space
             0x30...0x39, 0x41...0x5A, 0x61...0x7A, // ASCII digits and letters
             0x1100...0x11FF, 0x3131...0x318E, // Hangul jamo
             0xA960...0xA97C, 0xAC00...0xD7A3, 0xD7B0...0xD7C6, 0xD7CB...0xD7FB:
            return true
        default:
            return punctuation.contains(scalar)
        }
    }

    // Apply only after the control header has been interpreted. Raw model output
    // and its memory decision remain intact for evaluation and memory commits.
    func apply(to result: MemoryHeaderGateResult) -> MemoryHeaderGateResult {
        MemoryHeaderGateResult(
            decision: result.decision, syntax: result.syntax,
            rawText: result.rawText, visibleText: apply(to: result.visibleText),
            controlText: result.controlText
        )
    }
}
