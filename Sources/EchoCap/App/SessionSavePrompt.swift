import AppKit
import EchoCapCore

/// Asks, when a recording ends, whether to keep it — and optionally whether to
/// have the on-device model summarise it.
@MainActor
enum SessionSavePrompt {

    /// Ask about the recording that just finished.
    ///
    /// - Parameters:
    ///   - boxes: everything captured in this session, oldest first.
    ///   - startedAt: when the session began, used for the duration line.
    ///   - onFinish: called once the user is done (saved or dismissed), so the
    ///     caller can carry on with whatever it was doing — quitting, usually.
    static func present(
        boxes: [CaptionBox],
        startedAt: Date,
        summaryEngine: ModelEngine,
        cloud: CloudLLMConfig,
        onFinish: (() -> Void)? = nil
    ) {
        guard !boxes.isEmpty else {
            onFinish?()
            return
        }

        let minutes = max(1, Int(Date().timeIntervalSince(startedAt) / 60))

        let alert = NSAlert()
        alert.messageText = "本次记录结束"
        alert.informativeText =
            "共 \(boxes.count) 条字幕，时长约 \(minutes) 分钟。要保存下来吗？"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存…")
        alert.addButton(withTitle: "不保存")

        // Both engines are offered, so the choice is made here rather than in
        // Settings — which model to spend on depends on the recording.
        let choiceView = SummaryChoiceView(
            preferred: summaryEngine,
            localAvailability: SummaryService.availability(engine: .local, cloud: cloud),
            cloudAvailability: SummaryService.availability(engine: .cloud, cloud: cloud)
        )
        alert.accessoryView = choiceView

        guard alert.runModal() == .alertFirstButtonReturn else {
            onFinish?()
            return
        }

        let chosenEngine = choiceView.chosenEngine
        let wantsSummary = chosenEngine != nil
        guard let url = askForDestination() else {
            onFinish?()
            return
        }

        do {
            try TranscriptExporter.write(boxes: boxes, to: url)
        } catch {
            NSAlert(error: error).runModal()
            onFinish?()
            return
        }

        if let chosenEngine {
            summarise(
                boxes: boxes,
                transcriptURL: url,
                engine: chosenEngine,
                cloud: cloud,
                onFinish: onFinish
            )
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            onFinish?()
        }
    }

    /// Where to write the transcript. `nil` when the user cancels.
    private static func askForDestination() -> URL? {
        TranscriptSavePanel.present(baseName: defaultBaseName())
    }

    private static func defaultBaseName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "字幕记录 \(formatter.string(from: Date()))"
    }

    // MARK: - Summary

    private static func summarise(
        boxes: [CaptionBox],
        transcriptURL: URL,
        engine: ModelEngine,
        cloud: CloudLLMConfig,
        onFinish: (() -> Void)?
    ) {
        let transcript = TranscriptExporter.render(boxes: boxes, format: .plainText)

        Task {
            do {
                let summary = try await SummaryService.summarise(
                    transcript,
                    engine: engine,
                    cloud: cloud
                )
                write(summary: summary, nextTo: transcriptURL)
                SummaryWindowController.shared.show(
                    summary: summary,
                    subtitle: transcriptURL.lastPathComponent
                )
            } catch {
                let alert = NSAlert()
                alert.messageText = "没能生成摘要"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
            onFinish?()
        }
    }

    /// Put the summary at the top of a Markdown file, or alongside anything else.
    private static func write(summary: String, nextTo url: URL) {
        let isMarkdown = url.pathExtension.lowercased() == "md"
        guard isMarkdown else {
            let sibling = url.deletingPathExtension()
                .appendingPathExtension("summary.md")
            try? ("# 摘要\n\n" + summary + "\n").write(
                to: sibling, atomically: true, encoding: .utf8
            )
            return
        }
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        let combined = "# 摘要\n\n" + summary + "\n\n---\n\n" + existing
        try? combined.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A small window that shows a summary and lets the user copy it.
@MainActor
final class SummaryWindowController {
    static let shared = SummaryWindowController()

    private var window: NSWindow?

    func show(summary: String, subtitle: String) {
        let window = window ?? makeWindow()
        self.window = window

        textView?.string = summary
        subtitleLabel?.stringValue = subtitle
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var textView: NSTextView?
    private var subtitleLabel: NSTextField?

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI 摘要"
        window.center()

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        subtitleLabel = label

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextView()
        text.isEditable = false
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = text
        textView = text

        let copy = NSButton(title: "复制摘要", target: self, action: #selector(copySummary))
        let close = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        let buttons = NSStackView(views: [copy, close])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [label, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        window.setFrameAutosaveName("EchoCapSummary")
        return window
    }

    @objc private func copySummary() {
        guard let textView else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func closeWindow() {
        window?.orderOut(nil)
    }
}

/// The accessory view in the end-of-recording alert: a popup that picks which
/// model summarises, plus a line saying why an option is greyed out.
final class SummaryChoiceView: NSView {

    enum Choice: Int {
        case none = 0
        case local = 1
        case cloud = 2
    }

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hint = NSTextField(labelWithString: "")

    private let localAvailability: SummaryService.Availability
    private let cloudAvailability: SummaryService.Availability

    /// `nil` when the user does not want a summary.
    var chosenEngine: ModelEngine? {
        switch Choice(rawValue: popup.indexOfSelectedItem) {
        case .local: return .local
        case .cloud: return .cloud
        default: return nil
        }
    }

    init(
        preferred: ModelEngine,
        localAvailability: SummaryService.Availability,
        cloudAvailability: SummaryService.Availability
    ) {
        self.localAvailability = localAvailability
        self.cloudAvailability = cloudAvailability
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 56))

        popup.addItems(withTitles: ["不生成摘要", "用本机模型总结", "用云端 API 总结"])
        popup.item(at: Choice.local.rawValue)?.isEnabled = localAvailability.canSummarise
        popup.item(at: Choice.cloud.rawValue)?.isEnabled = cloudAvailability.canSummarise
        if !localAvailability.canSummarise {
            popup.item(at: Choice.local.rawValue)?.title = "用本机模型总结（不可用）"
        }
        if !cloudAvailability.canSummarise {
            popup.item(at: Choice.cloud.rawValue)?.title = "用云端 API 总结（未配置）"
        }

        // Start on whichever engine the settings point at, if it can run.
        switch preferred {
        case .local:
            popup.selectItem(at: localAvailability.canSummarise ? Choice.local.rawValue : Choice.none.rawValue)
        case .cloud:
            popup.selectItem(at: cloudAvailability.canSummarise ? Choice.cloud.rawValue : Choice.none.rawValue)
        }

        popup.target = self
        popup.action = #selector(selectionChanged)

        let label = NSTextField(labelWithString: "总结方式：")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let column = NSStackView(views: [row, hint])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
        ])

        updateHint()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func selectionChanged() {
        updateHint()
    }

    private func updateHint() {
        var reasons: [String] = []
        if case .unavailable(let reason) = localAvailability {
            reasons.append("本机不可用：\(reason)")
        }
        if case .unavailable(let reason) = cloudAvailability {
            reasons.append("云端不可用：\(reason)")
        }

        if !reasons.isEmpty {
            hint.stringValue = reasons.joined(separator: "；")
            return
        }
        hint.stringValue = "本机模型不联网；云端按你配置的接口计费。"
    }
}
