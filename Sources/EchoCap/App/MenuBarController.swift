import AppKit
import EchoCapCore

/// The menu bar item and its menu.
@available(macOS 26.0, *)
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let controller: AppController
    private var statusItem: NSStatusItem?
    private var settingsItem: NSMenuItem?

    /// Languages that can actually be recognised on this machine.
    private var recognitionLanguages: [LanguageCatalog.Language] = []

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.makeIcon()
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "EchoCap 实时字幕"
        statusItem = item
        rebuildMenu()
    }

    /// A simple waveform glyph, drawn so we do not need a bundled asset.
    private static func makeIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        let heights: [CGFloat] = [5, 11, 15, 9]
        for (index, height) in heights.enumerated() {
            let x = 2.5 + CGFloat(index) * 4.2
            path.move(to: NSPoint(x: x, y: 9 - height / 2))
            path.line(to: NSPoint(x: x, y: 9 + height / 2))
        }
        path.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.delegate = self

        // Pause / Resume
        let pause = NSMenuItem(
            title: controller.isRunning ? "暂停字幕" : "开始字幕",
            action: #selector(toggleCapture),
            keyEquivalent: "s"
        )
        pause.keyEquivalentModifierMask = [.command, .option]
        pause.target = self
        menu.addItem(pause)

        // Listen To
        let listenTo = NSMenuItem(title: "聆听对象", action: nil, keyEquivalent: "")
        let listenMenu = NSMenu()
        for source in AudioSource.allCases {
            let item = NSMenuItem(
                title: source.displayName,
                action: #selector(selectSource(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = source
            item.state = controller.settings.source == source ? .on : .off
            listenMenu.addItem(item)
        }
        listenTo.submenu = listenMenu
        menu.addItem(listenTo)

        // Translate To
        let translateTo = NSMenuItem(title: "翻译为", action: nil, keyEquivalent: "")
        let translateMenu = NSMenu()
        let off = NSMenuItem(title: "关闭", action: #selector(selectTranslation(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = nil as String?
        off.state = controller.settings.translationTarget == nil ? .on : .off
        translateMenu.addItem(off)
        translateMenu.addItem(.separator())
        for language in LanguageCatalog.all {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(selectTranslation(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.id
            item.state = controller.settings.translationTarget == language.id ? .on : .off
            translateMenu.addItem(item)
        }
        translateTo.submenu = translateMenu
        menu.addItem(translateTo)

        // Show both languages
        let both = NSMenuItem(
            title: "同时显示两种语言",
            action: #selector(toggleShowBoth),
            keyEquivalent: ""
        )
        both.target = self
        both.state = controller.settings.showBothLanguages ? .on : .off
        menu.addItem(both)

        // Language / Models
        let languageItem = NSMenuItem(title: "识别语言", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let auto = NSMenuItem(title: "自动检测", action: #selector(selectRecognitionLanguage(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = nil as String?
        auto.state = controller.settings.recognitionLanguage == nil ? .on : .off
        languageMenu.addItem(auto)
        languageMenu.addItem(.separator())
        for language in recognitionLanguages {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(selectRecognitionLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.id
            item.state = controller.settings.recognitionLanguage == language.id ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        // Text size
        let textSize = NSMenuItem(title: "文字大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for size in [18.0, 22.0, 28.0, 34.0, 42.0] {
            let item = NSMenuItem(
                title: "\(Int(size))",
                action: #selector(selectFontSize(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = size
            item.state = abs(controller.settings.fontSize - size) < 0.5 ? .on : .off
            sizeMenu.addItem(item)
        }
        textSize.submenu = sizeMenu
        menu.addItem(textSize)

        // Alignment
        let alignment = NSMenuItem(title: "对齐", action: nil, keyEquivalent: "")
        let alignmentMenu = NSMenu()
        for option in CaptionAlignment.allCases {
            let item = NSMenuItem(
                title: option.displayName,
                action: #selector(selectAlignment(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option
            item.state = controller.settings.alignment == option ? .on : .off
            alignmentMenu.addItem(item)
        }
        alignment.submenu = alignmentMenu
        menu.addItem(alignment)

        // Show source app name
        let sourceName = NSMenuItem(
            title: "显示来源应用名称",
            action: #selector(toggleSourceAppName),
            keyEquivalent: ""
        )
        sourceName.target = self
        sourceName.state = controller.settings.showSourceAppName ? .on : .off
        menu.addItem(sourceName)

        // Fade away under pointer
        let fade = NSMenuItem(
            title: "指针下方淡出",
            action: #selector(toggleFadeUnderPointer),
            keyEquivalent: ""
        )
        fade.target = self
        fade.state = controller.settings.fadeAwayUnderPointer ? .on : .off
        menu.addItem(fade)

        menu.addItem(.separator())

        // Save transcript
        let save = NSMenuItem(title: "存储文字记录…", action: #selector(saveTranscript), keyEquivalent: "s")
        save.keyEquivalentModifierMask = .command
        save.target = self
        menu.addItem(save)

        // Reset overlay position
        let reset = NSMenuItem(title: "重置浮层位置", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        // Settings
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        self.settingsItem = settingsItem

        menu.addItem(.separator())

        // Status
        let status = NSMenuItem(title: controller.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let error = controller.lastError {
            let errorItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        let quit = NSMenuItem(title: "退出 EchoCap", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Menu delegate

    func menuWillOpen(_ menu: NSMenu) {
        refreshRecognitionLanguages()
        rebuildMenu()
    }

    private func refreshRecognitionLanguages() {
        Task {
            let installed = await SpeechEngine.installedRecognitionLocales()
            await MainActor.run {
                self.recognitionLanguages = LanguageCatalog.recognitionLanguages(installed: installed)
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleCapture() {
        Task { await controller.toggle() }
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? AudioSource else { return }
        Task { await controller.switchSource(source) }
    }

    @objc private func selectTranslation(_ sender: NSMenuItem) {
        let target = sender.representedObject as? String
        controller.settings.translationTarget = target
        Task { await controller.reconfigure() }
    }

    @objc private func toggleShowBoth() {
        controller.settings.showBothLanguages.toggle()
    }

    @objc private func selectRecognitionLanguage(_ sender: NSMenuItem) {
        let language = sender.representedObject as? String
        controller.settings.recognitionLanguage = language
        Task { await controller.reconfigure() }
    }

    @objc private func selectFontSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? Double else { return }
        controller.settings.fontSize = size
    }

    @objc private func selectAlignment(_ sender: NSMenuItem) {
        guard let option = sender.representedObject as? CaptionAlignment else { return }
        controller.settings.alignment = option
    }

    @objc private func toggleSourceAppName() {
        controller.settings.showSourceAppName.toggle()
    }

    @objc private func toggleFadeUnderPointer() {
        controller.settings.fadeAwayUnderPointer.toggle()
    }

    @objc private func saveTranscript() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "字幕记录.srt"
        panel.allowedContentTypes = []
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.controller.saveTranscript(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func resetPosition() {
        controller.resetOverlayPosition()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
