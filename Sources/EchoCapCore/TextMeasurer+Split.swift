import Foundation
import CoreText

public extension TextMeasurer {
    /// Longest prefix of `text` that fits within `maxLines` visual lines.
    ///
    /// The result is trimmed back to a word boundary when possible so we never
    /// cut a word in half mid-sentence.
    static func prefixFitting(
        text: String,
        maxLines: Int,
        fontSize: Double,
        width: CGFloat
    ) -> (fitted: String, overflow: String) {
        guard !text.isEmpty else { return ("", "") }
        guard maxLines > 0 else { return ("", text) }

        let font = TextMeasurer.systemFont(size: fontSize)
        let full = lineCount(text: text, font: font, width: width)
        if full <= maxLines { return (text, "") }

        // Binary search the largest character count that still fits.
        let chars = Array(text)
        var low = 0
        var high = chars.count
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            let candidate = String(chars[0..<mid])
            if lineCount(text: candidate, font: font, width: width) <= maxLines {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        var cut = best
        if cut > 0 && cut < chars.count {
            // Prefer to break at whitespace so words stay intact.
            let slice = String(chars[0..<cut])
            if let lastSpace = slice.lastIndex(where: { $0 == " " || $0 == "\n" }),
               slice.distance(from: slice.startIndex, to: lastSpace) > 0 {
                cut = slice.distance(from: slice.startIndex, to: lastSpace)
            }
        }
        if cut <= 0 { cut = best }

        let fitted = String(chars[0..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        let overflow = String(chars[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (fitted, overflow)
    }
}
