import Foundation

/// Turns the recogniser's cumulative output into segment-level events.
///
/// Apple's Speech framework reports the text of the whole current range on
/// every update, revising it as more audio arrives. A caption pipeline wants
/// to know two things instead: what the current segment reads like *right
/// now*, and when a segment has closed for good.
///
/// Keeping the segment's cumulative text (rather than the difference between
/// two updates) is what makes mid-sentence corrections work: when the
/// recogniser changes "EchoCab" to "EchoCap", the caption simply shows the
/// corrected text instead of carrying a stale fragment forever.
///
/// Segments are recognised from the text itself rather than from the reported
/// range: the framework closes a segment with a range that differs from the
/// one it used while the segment was open, so the range cannot be used as the
/// segment's identity.
public final class TranscriptAssembler {

    /// What changed since the last call.
    public struct Update: Equatable {
        /// The cumulative text of the segment.
        public let text: String
        /// A number that increases every time a new segment begins.
        public let segmentIndex: Int
        /// `true` when the recogniser moved on to a new segment.
        public let isNewSegment: Bool
        /// `true` when the segment will not be revised further.
        public let isFinal: Bool
    }

    /// The text of the segment currently being recognised.
    private var openText: String = ""
    /// Index of the segment currently being recognised.
    private var openSegmentIndex: Int = 0
    /// Index handed to the next segment that begins.
    private var nextSegmentIndex: Int = 1
    /// Closed segments, in order.
    private var closedSegments: [(index: Int, text: String)] = []

    /// Text of the segment being recognised right now.
    public var volatileText: String { openText }

    /// Text of every closed segment, joined with a space.
    public var committedText: String {
        closedSegments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    public init() {}

    /// Feed one recogniser result.
    ///
    /// - Parameters:
    ///   - text: the recogniser's cumulative reading of the segment.
    ///   - isFinal: whether the recogniser will not revise this text further.
    /// - Returns: what changed.
    public func ingest(text: String, isFinal: Bool) -> Update {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Update(
                text: openText,
                segmentIndex: openSegmentIndex,
                isNewSegment: false,
                isFinal: isFinal
            )
        }

        if isFinal {
            // The segment is closed. The final text is authoritative, so it
            // replaces whatever the open segment was showing.
            close(text: trimmed)
            openText = ""
            openSegmentIndex = nextSegmentIndex
            nextSegmentIndex += 1
            return Update(
                text: trimmed,
                segmentIndex: openSegmentIndex - 1,
                isNewSegment: true,
                isFinal: true
            )
        }

        if openText.isEmpty {
            openText = trimmed
            return Update(
                text: trimmed,
                segmentIndex: openSegmentIndex,
                isNewSegment: true,
                isFinal: false
            )
        }

        if Self.isRevision(of: openText, by: trimmed) {
            // The recogniser refined the same sentence — show the new wording.
            openText = trimmed
            return Update(
                text: trimmed,
                segmentIndex: openSegmentIndex,
                isNewSegment: false,
                isFinal: false
            )
        }

        // A genuinely new utterance began: close the previous one first.
        close(text: openText)
        openText = trimmed
        openSegmentIndex = nextSegmentIndex
        nextSegmentIndex += 1
        return Update(
            text: trimmed,
            segmentIndex: openSegmentIndex,
            isNewSegment: true,
            isFinal: false
        )
    }

    /// Text of a closed segment, by its index.
    public func committedText(forSegment index: Int) -> String {
        closedSegments.first { $0.index == index }?.text ?? ""
    }

    /// Forget everything.
    public func reset() {
        openText = ""
        openSegmentIndex = 0
        nextSegmentIndex = 1
        closedSegments.removeAll()
    }

    // MARK: - Helpers

    private func close(text: String) {
        guard !text.isEmpty else { return }
        if let existing = closedSegments.firstIndex(where: { $0.index == openSegmentIndex }) {
            closedSegments[existing].text = text
        } else {
            closedSegments.append((index: openSegmentIndex, text: text))
        }
    }

    /// Whether `new` is a refinement of `old` rather than a new sentence.
    ///
    /// A refinement shares most of its prefix with what came before; a new
    /// sentence does not.
    static func isRevision(of old: String, by new: String) -> Bool {
        if new.hasPrefix(old) { return true }
        let shared = commonPrefixLength(old, new)
        let shorter = min(old.count, new.count)
        guard shorter > 0 else { return false }
        return Double(shared) >= Double(shorter) * 0.6
    }

    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var i = 0
        while i < x.count, i < y.count, x[i] == y[i] { i += 1 }
        return i
    }
}
