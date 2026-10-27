import Foundation

/// Drives caption boxes: paginates incoming text into screenfuls, keeps the
/// rewindable history stack, and answers search queries.
///
/// Deliberately free of AppKit so the paging rules can be unit tested.
public final class CaptionPipeline {
    /// A sealed or live box plus the moment it should stop being visible.
    public struct Entry: Equatable {
        public let box: CaptionBox
        public let isLive: Bool
    }

    private var live: CaptionBox?
    private var history: [CaptionBox] = []
    private var lastActivity: Date = Date()

    /// Text of the segment being recognised, shown live.
    private var volatileText: String = ""

    /// Text of closed segments that has not yet been placed into a box.
    private var pending: String = ""

    /// Segments already committed, so a repeated final does not duplicate them.
    private var committedSegmentIDs: Set<Int> = []

    /// The segment currently open, if any.
    private var openSegmentID: Int?

    public var settings: AppSettings

    public init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    // MARK: - Ingest

    /// Feed one segment update from the recogniser.
    ///
    /// - Parameters:
    ///   - text: the segment's cumulative text, as the recogniser sees it now.
    ///   - segmentID: identifies the segment, so it is committed only once.
    ///   - isNewSegment: `true` when the recogniser moved on to a new segment.
    ///   - isFinal: `true` when the segment is closed for good.
    ///   - sourceAppName: app the audio came from, when known.
    public func ingest(
        text: String,
        segmentID: Int,
        isNewSegment: Bool = false,
        isFinal: Bool = false,
        sourceAppName: String? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastActivity = Date()

        if isNewSegment && !volatileText.isEmpty {
            // The previous segment is complete — commit it before moving on.
            commit(volatileText, segmentID: openSegmentID ?? segmentID, sourceAppName: sourceAppName)
            volatileText = ""
        }

        if isFinal {
            // The segment is closed: the final wording is authoritative.
            commit(trimmed, segmentID: segmentID, sourceAppName: sourceAppName)
            volatileText = ""
            live?.setVolatile("")
        } else {
            // Still being revised — show the recogniser's current reading.
            volatileText = trimmed
            openSegmentID = segmentID
            if live == nil {
                live = CaptionBox(sourceAppName: sourceAppName)
            }
            live?.setVolatile(volatileText)
        }
    }

    /// Move a segment's text into the committed pool and paginate.
    private func commit(_ text: String, segmentID: Int, sourceAppName: String?) {
        guard !text.isEmpty else { return }
        guard !committedSegmentIDs.contains(segmentID) else { return }
        committedSegmentIDs.insert(segmentID)

        pending = pending.isEmpty ? text : pending + " " + text
        paginate(sourceAppName: sourceAppName)
    }

    /// Attach a translation to the live box.
    public func setTranslation(_ text: String, isFinal: Bool) {
        guard !text.isEmpty else { return }
        if isFinal {
            live?.setTranslation(text)
        } else {
            live?.setVolatileTranslation(text)
        }
    }

    /// Force the current box closed — used when the speaker changes.
    public func sealCurrentBox() {
        if !volatileText.isEmpty {
            commit(volatileText, segmentID: openSegmentID ?? -1, sourceAppName: nil)
            volatileText = ""
        }
        guard var box = live, !box.displayText.isEmpty else { return }
        box.seal()
        history.append(box)
        live = nil
        pending = ""
    }

    // MARK: - Pagination

    /// Split pending text into boxes that each fit within `linesPerBox` lines.
    private func paginate(sourceAppName: String?) {
        let width = measurementWidth
        let maxLines = max(1, settings.linesPerBox)

        while true {
            let existing = live?.committedText ?? ""
            let combined = existing.isEmpty ? pending : existing + " " + pending

            let lines = TextMeasurer.lineCount(
                text: combined,
                fontSize: settings.fontSize,
                width: width
            )

            if lines <= maxLines {
                // Still fits — commit the whole thing into the live box.
                if live == nil {
                    live = CaptionBox(sourceAppName: sourceAppName)
                }
                live?.setCommitted(combined)
                pending = ""
                return
            }

            // Too long — fill one box and carry the rest over.
            let (fitted, overflow) = TextMeasurer.prefixFitting(
                text: combined,
                maxLines: maxLines,
                fontSize: settings.fontSize,
                width: width
            )

            var box = live ?? CaptionBox(sourceAppName: sourceAppName)
            box.setCommitted(fitted)
            box.seal()
            history.append(box)

            live = nil
            pending = overflow
            if overflow.isEmpty { return }
        }
    }

    /// Approximate usable width of the overlay box, in points.
    /// Width the caption text is measured against, in points.
    ///
    /// Follows the overlay's real width so pagination and the line clip agree
    /// with what is actually on screen after the user resizes it.
    public var measurementWidth: CGFloat = defaultOverlayWidth

    /// Width used before the overlay reports its own size.
    public static let defaultOverlayWidth: CGFloat = 1100

    // MARK: - Reading state

    /// The live box, if there is one.
    public var liveBox: CaptionBox? { live }

    /// The rewindable history, oldest first.
    public var historyBoxes: [CaptionBox] { history }

    /// Boxes currently worth drawing: the live box plus the last N history boxes.
    public func visibleBoxes(now: Date = Date()) -> [Entry] {
        var entries: [Entry] = []
        if let live, !live.displayText.isEmpty {
            entries.append(Entry(box: live, isLive: true))
        }
        let depth = settings.historyDepth
        let recent = depth == Int.max ? history : Array(history.suffix(depth))
        for box in recent where !box.displayText.isEmpty {
            entries.append(Entry(box: box, isLive: false))
        }
        return entries
    }

    /// Whether the live box has been quiet long enough to fade out.
    public func shouldFadeLiveBox(now: Date = Date()) -> Bool {
        guard let live, !live.displayText.isEmpty else { return true }
        return now.timeIntervalSince(live.lastTextAt) >= settings.fadeDelay
    }

    /// Whether the whole history stack should be dropped for inactivity.
    public func shouldClearHistory(now: Date = Date()) -> Bool {
        let timeout = settings.historyTimeout
        guard timeout > 0 else { return false }
        return now.timeIntervalSince(lastActivity) > timeout
    }

    /// Drop the history stack (called on pause or on timeout).
    public func clearHistory() {
        history.removeAll()
    }

    /// Forget everything, including the live box.
    public func reset() {
        live = nil
        history.removeAll()
        pending = ""
        volatileText = ""
        committedSegmentIDs.removeAll()
        openSegmentID = nil
        lastActivity = Date()
    }

    // MARK: - Search

    /// Search the history stack. An empty query returns everything.
    public func search(_ query: String) -> [CaptionBox] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return history }
        return history.filter { box in
            box.displayText.localizedCaseInsensitiveContains(needle)
                || (box.sourceAppName?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }
}
