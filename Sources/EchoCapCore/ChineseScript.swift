import Foundation

/// Script helpers for Chinese output.
///
/// Apple's translation model for Chinese is a single model for both scripts and
/// does not reliably honour the requested variant: the same session can return
/// Simplified for one sentence and Traditional for the next. Folding every
/// result keeps a transcript in one script.
public enum ChineseScript {
    /// Convert any Traditional characters in `text` to Simplified.
    ///
    /// Text that is already Simplified comes back unchanged.
    public static func toSimplified(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false)
            ?? text
    }

    /// Whether mixed Simplified and Traditional characters appear together.
    ///
    /// Used by the tests, and useful when deciding whether folding is needed.
    public static func containsTraditionalCharacters(_ text: String) -> Bool {
        toSimplified(text) != text
    }
}
