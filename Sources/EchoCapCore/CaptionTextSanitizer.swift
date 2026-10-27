import Foundation

/// Decides whether a recognition result is speech at all.
///
/// Starting a system-audio tap makes a click, and the recogniser dutifully
/// transcribes it — a burst of quotes and stray letters appears at the top of
/// the first caption of every session. Dropping the leading audio helps, and
/// this catches whatever is left.
public enum CaptionTextSanitizer {

    /// True when `text` is almost certainly noise rather than speech.
    ///
    /// Deliberately conservative: real short utterances ("OK", "好。") are kept,
    /// punctuation soup (`'I'"I'""'.'`) is not.
    public static func isNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        var letters = 0
        var digits = 0
        var punctuation = 0
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letters += 1
            } else if CharacterSet.decimalDigits.contains(scalar) {
                digits += 1
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            } else {
                punctuation += 1
            }
        }

        let meaningful = letters + digits
        guard meaningful > 0 else { return true }
        // A couple of letters buried in punctuation: `'I'"I'""'.'`
        if meaningful <= 3, punctuation > meaningful { return true }
        // Punctuation outweighs the words by more than two to one.
        if punctuation > meaningful * 2 { return true }
        return false
    }
}
