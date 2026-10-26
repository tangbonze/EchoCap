import Foundation
import CoreText

/// Measures how many lines a string occupies once wrapped.
///
/// Uses CoreText rather than AppKit so the pagination logic stays testable
/// without a window server.
public enum TextMeasurer {
    /// Approximate line height used when CoreText cannot give us a precise one.
    static let fallbackLineHeight: CGFloat = 22

    /// The system font at `size`, used for measuring.
    ///
    /// `CTFontCreateWithName` silently falls back to Helvetica for names that
    /// are not installed, so ask the system for its UI font instead.
    public static func systemFont(size: Double) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(size), nil)
    }

    /// Number of visual lines `text` occupies when wrapped to `width` points.
    public static func lineCount(text: String, font: CTFont, width: CGFloat) -> Int {
        guard !text.isEmpty, width > 1 else { return text.isEmpty ? 0 : 1 }

        let attributed = NSAttributedString(
            string: text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)

        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length > 0 else { return 0 }

        // Count the line origins CoreText produced.
        let lines = CTFrameGetLines(frame)
        let count = CFArrayGetCount(lines)
        if count > 0 { return count }

        // Fallback: derive from the suggested frame size.
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        let oneLine = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: min(1, attributed.length)),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        let lineHeight = oneLine.height > 0 ? oneLine.height : fallbackLineHeight
        return max(1, Int(ceil(suggested.height / max(lineHeight, 1))))
    }

    /// Number of lines for `text` at a given point size, using the system font.
    public static func lineCount(text: String, fontSize: Double, width: CGFloat) -> Int {
        lineCount(text: text, font: systemFont(size: fontSize), width: width)
    }
}
