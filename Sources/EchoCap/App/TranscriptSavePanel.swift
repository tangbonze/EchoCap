import AppKit
import UniformTypeIdentifiers

/// The save panel used for transcripts.
///
/// Only two formats are offered — Markdown, which keeps timestamps and the
/// translation, and plain text. A format popup is clearer than expecting people
/// to retype the extension.
@MainActor
enum TranscriptSavePanel {

    static func present(baseName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存字幕记录"
        panel.canCreateDirectories = true

        let accessory = TranscriptFormatAccessoryView()
        panel.accessoryView = accessory
        accessory.attach(to: panel, baseName: baseName)

        // Both formats are plain text underneath; the extension decides which.
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]

        guard panel.runModal() == .OK, var url = panel.url else { return nil }

        // Whatever was typed, land on one of the two supported extensions.
        let allowed = ["md", "txt"]
        if !allowed.contains(url.pathExtension.lowercased()) {
            url = url.deletingPathExtension()
                .appendingPathExtension(accessory.selectedExtension)
        }
        return url
    }
}

/// "格式：" plus a two-item popup, kept in sync with the panel's file name.
final class TranscriptFormatAccessoryView: NSView {

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?
    private var baseName = "字幕记录"

    private static let formats: [(title: String, ext: String)] = [
        ("Markdown (.md)", "md"),
        ("纯文本 (.txt)", "txt"),
    ]

    var selectedExtension: String {
        let index = max(0, min(popup.indexOfSelectedItem, Self.formats.count - 1))
        return Self.formats[index].ext
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        popup.addItems(withTitles: Self.formats.map(\.title))
        popup.target = self
        popup.action = #selector(formatChanged)
        popup.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "格式：")
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(popup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            heightAnchor.constraint(equalToConstant: 44),
            widthAnchor.constraint(equalToConstant: 300),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func attach(to panel: NSSavePanel, baseName: String) {
        self.panel = panel
        self.baseName = baseName
        updateFileName()
    }

    @objc private func formatChanged() {
        updateFileName()
    }

    private func updateFileName() {
        panel?.nameFieldStringValue = "\(baseName).\(selectedExtension)"
    }
}
