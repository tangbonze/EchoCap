import Foundation

/// A single caption "box" — the unit the overlay renders as one screenful of text.
///
/// The product this imitates behaves like broadcast captions: text fills a box
/// up to a line limit, the box is then cleared and a new one starts.
public struct CaptionBox: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Text that has been committed (final) into this box.
    public private(set) var committedText: String
    /// Text that is still being revised by the recogniser (not final).
    public private(set) var volatileText: String
    /// Translation of `committedText`, when translation is enabled and available.
    public private(set) var translation: String
    /// Translation of `volatileText`.
    public private(set) var volatileTranslation: String
    /// Name of the app that produced this audio, when it could be determined.
    public private(set) var sourceAppName: String?
    public let createdAt: Date
    public private(set) var lastTextAt: Date
    /// When the box was sealed and pushed into history.
    public private(set) var sealedAt: Date?

    public init(
        id: UUID = UUID(),
        committedText: String = "",
        volatileText: String = "",
        translation: String = "",
        volatileTranslation: String = "",
        sourceAppName: String? = nil,
        createdAt: Date = Date(),
        lastTextAt: Date = Date()
    ) {
        self.id = id
        self.committedText = committedText
        self.volatileText = volatileText
        self.translation = translation
        self.volatileTranslation = volatileTranslation
        self.sourceAppName = sourceAppName
        self.createdAt = createdAt
        self.lastTextAt = lastTextAt
    }

    /// The text a reader would actually see right now.
    public var displayText: String {
        if volatileText.isEmpty { return committedText }
        if committedText.isEmpty { return volatileText }
        return committedText + " " + volatileText
    }

    public var displayTranslation: String {
        if volatileTranslation.isEmpty { return translation }
        if translation.isEmpty { return volatileTranslation }
        return translation + " " + volatileTranslation
    }

    /// `displayText` without any trailing whitespace.
    public var trimmedText: String {
        displayText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The tail of `displayText` that fits within `maxLines` lines.
    ///
    /// A segment that is still being recognised keeps growing between commits,
    /// so the live box can outgrow the line budget. Rather than let it push the
    /// overlay taller and taller, the newest words are kept and the oldest drop
    /// off — the way broadcast captions scroll.
    ///
    /// Works for both space-separated languages and CJK, which has no spaces.
    public func visibleText(maxLines: Int, fontSize: Double, width: Double) -> String {
        let full = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxLines > 0, !full.isEmpty else { return full }
        guard TextMeasurer.lineCount(text: full, fontSize: fontSize, width: width) > maxLines else {
            return full
        }

        let usesSpaces = full.contains(" ")
        let units: [String] = usesSpaces
            ? full.split(separator: " ").map(String.init)
            : full.map(String.init)
        guard units.count > 1 else { return full }

        func render(from index: Int) -> String {
            usesSpaces
                ? units[index...].joined(separator: " ")
                : units[index...].joined()
        }

        // Drop leading units until the remainder fits. Line count falls
        // monotonically as units are dropped, so a binary search is enough.
        var low = 1
        var high = units.count - 1
        var firstKept = units.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if TextMeasurer.lineCount(
                text: render(from: middle), fontSize: fontSize, width: width
            ) <= maxLines {
                firstKept = middle
                high = middle - 1
            } else {
                low = middle + 1
            }
        }
        return render(from: firstKept)
    }

    public var isEmpty: Bool { displayText.isEmpty }

    /// True once the box has been sealed into history.
    public var isSealed: Bool { sealedAt != nil }

    // MARK: - Mutation

    mutating func setCommitted(_ text: String) {
        committedText = text
        lastTextAt = Date()
    }

    mutating func setVolatile(_ text: String) {
        volatileText = text
        // Only refresh the fade clock when *new* text appears.
        if !text.isEmpty { lastTextAt = Date() }
    }

    mutating func setTranslation(_ text: String) {
        translation = text
        // The live translation has been superseded by the settled one;
        // keeping both would show the sentence twice.
        volatileTranslation = ""
    }

    mutating func setVolatileTranslation(_ text: String) {
        volatileTranslation = text
    }

    mutating func setSourceAppName(_ name: String?) {
        sourceAppName = name
    }

    mutating func seal(at date: Date = Date()) {
        sealedAt = date
        volatileText = ""
        volatileTranslation = ""
    }
}
