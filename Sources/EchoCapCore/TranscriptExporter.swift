import Foundation

/// Exports a captioned session to plain text, Markdown, or SRT.
public enum TranscriptExporter {
    public enum Format: String, CaseIterable, Sendable {
        case plainText
        case markdown
        case srt

        public var displayName: String {
            switch self {
            case .plainText: return "纯文本 (.txt)"
            case .markdown: return "Markdown (.md)"
            case .srt: return "SRT 字幕 (.srt)"
            }
        }

        public var fileExtension: String {
            switch self {
            case .plainText: return "txt"
            case .markdown: return "md"
            case .srt: return "srt"
            }
        }
    }

    /// Render `boxes` in the requested format.
    public static func render(boxes: [CaptionBox], format: Format) -> String {
        switch format {
        case .plainText: return renderPlainText(boxes)
        case .markdown: return renderMarkdown(boxes)
        case .srt: return renderSRT(boxes)
        }
    }

    /// Write the transcript to `url`, choosing a format from the file extension.
    @discardableResult
    public static func write(boxes: [CaptionBox], to url: URL) throws -> Int {
        let format: Format
        switch url.pathExtension.lowercased() {
        case "md", "markdown": format = .markdown
        case "srt": format = .srt
        default: format = .plainText
        }
        let text = render(boxes: boxes, format: format)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return text.utf8.count
    }

    private static func renderPlainText(_ boxes: [CaptionBox]) -> String {
        boxes.map { box in
            var line = box.displayText
            if let source = box.sourceAppName, !source.isEmpty {
                line = "[\(source)] \(line)"
            }
            return line
        }.joined(separator: "\n")
    }

    private static func renderMarkdown(_ boxes: [CaptionBox]) -> String {
        var out = "# 字幕记录\n\n"
        for box in boxes {
            if let source = box.sourceAppName, !source.isEmpty {
                out += "**\(source)** · \(timestamp(box.createdAt))\n\n"
            } else {
                out += "\(timestamp(box.createdAt))\n\n"
            }
            out += box.displayText + "\n\n"
            if !box.translation.isEmpty {
                out += "> \(box.translation)\n\n"
            }
        }
        return out
    }

    private static func renderSRT(_ boxes: [CaptionBox]) -> String {
        var out = ""
        for (index, box) in boxes.enumerated() {
            let start = box.createdAt
            let end = box.sealedAt ?? box.lastTextAt
            out += "\(index + 1)\n"
            out += "\(srtTime(start)) --> \(srtTime(end))\n"
            out += box.displayText + "\n"
            if !box.translation.isEmpty {
                out += box.translation + "\n"
            }
            out += "\n"
        }
        return out
    }

    private static func srtTime(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let parts = cal.dateComponents([.hour, .minute, .second], from: date)
        let ms = Int(date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1000)
        return String(
            format: "%02d:%02d:%02d,%03d",
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, ms
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
