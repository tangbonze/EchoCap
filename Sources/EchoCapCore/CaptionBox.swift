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
