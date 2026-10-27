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
        controller.onStateChanged = { [weak self] in
            self?.rebuildMenu()
            self?.refreshStatusItem()
        }
        rebuildMenu()
        refreshStatusItem()
    }

    /// Dim the menu-bar icon while nothing is being captured, so the state is
    /// visible without opening the menu.
    private func refreshStatusItem() {
        let running = controller.isRunning
        statusItem?.button?.appearsDisabled = !running
        let shortcut = controller.hotKeyLabel
        statusItem?.button?.toolTip = running
            ? "EchoCap 正在聆听（\(shortcut) 暂停）"
            : "EchoCap 已暂停（\(shortcut) 开始）"
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

        // Start / stop. The shortcut is shown in the title rather than set as a
        // key equivalent: a global hot key already owns that combination, and
        // having both would toggle twice whenever the menu is showing.
        let shortcut = controller.hotKeyLabel
        let pause = NSMenuItem(
            title: controller.isRunning
                ? "暂停聆听（\(shortcut)）"
                : "开始聆听（\(shortcut)）",
            action: #selector(toggleCapture),
            keyEquivalent: ""
        )
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

        // Move / resize the overlay. Off by default: while it is on the
        // overlay takes clicks like a normal window, which is exactly what you
        // do not want while reading along with something else.
        let layout = NSMenuItem(
            title: controller.isEditingLayout ? "完成浮层调整" : "调整浮层位置与大小",
            action: #selector(toggleLayoutEditing),
            keyEquivalent: "l"
        )
        layout.keyEquivalentModifierMask = [.command, .option]
        layout.target = self
        layout.state = controller.isEditingLayout ? .on : .off
        menu.addItem(layout)

        // Settings. No key equivalent: one is not assigned, and macOS otherwise
        // puts a gear glyph next to this item that none of the others have.
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: "")
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

    /// Titles of the current menu, for the `--dump-menu` debug flag.
    func menuTitlesForDebug() -> [String] {
        rebuildMenu()
        return (statusItem?.menu?.items ?? []).map {
            $0.isSeparatorItem ? "—" : ($0.title.isEmpty ? "(无标题)" : $0.title)
        }
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
        Task {
            await controller.toggle()
            rebuildMenu()
            refreshStatusItem()
        }
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


    @objc private func selectRecognitionLanguage(_ sender: NSMenuItem) {
        let language = sender.representedObject as? String
        controller.settings.recognitionLanguage = language
        Task { await controller.reconfigure() }
    }





    @objc private func toggleLayoutEditing() {
        controller.toggleLayoutEditing()
    }


    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        controller.requestQuit()
    }
}
