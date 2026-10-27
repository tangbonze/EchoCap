import AppKit
import Carbon.HIToolbox
import EchoCapCore

/// Entry point. Wires the app delegate, menu bar, and global shortcuts.
@main
struct EchoCapMain {
    static func main() {
        // Diagnostic modes, useful for verifying the pipeline from a terminal.
        let arguments = CommandLine.arguments
        if arguments.contains("--render-icon"), let index = arguments.firstIndex(of: "--render-icon") {
            let output = index + 1 < arguments.count
                ? URL(fileURLWithPath: arguments[index + 1])
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("EchoCap.icns")
            MainActor.assumeIsolated {
                do {
                    try AppIconRenderer.writeICNS(
                        to: output,
                        iconsetDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent("EchoCap.iconset")
                    )
                    print("已生成图标: \(output.path)")
                } catch {
                    print("生成图标失败: \(error.localizedDescription)")
                }
            }
            return
        }

        // Open the settings window at launch, for screenshots and checks.
        if arguments.contains("--show-settings") {
            let tab: SettingsTab = arguments.contains("behaviour") ? .behaviour : .appearance
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                SettingsWindowController.shared.show(initialTab: tab)
            }
        }

        // Store a cloud API key without going through the settings window.
        if arguments.contains("--set-api-key"), let index = arguments.firstIndex(of: "--set-api-key"),
           index + 1 < arguments.count {
            CloudCredentialStore.setAPIKey(arguments[index + 1])
            let stored = CloudCredentialStore.apiKey()
            print(stored.isEmpty ? "已清除 API Key" : "已保存 API Key（\(stored.count) 字符）")
            return
        }

        if arguments.contains("--render-settings"), let index = arguments.firstIndex(of: "--render-settings") {
            let output = index + 1 < arguments.count
                ? URL(fileURLWithPath: arguments[index + 1])
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("echocap-settings.png")
            let tab: SettingsTab = arguments.contains("behaviour") ? .behaviour : .appearance
            MainActor.assumeIsolated {
                UIPreviewRenderer.renderSettings(to: output, tab: tab)
                print("已渲染设置预览: \(output.path)")
            }
            return
        }

        if arguments.contains("--render-about"), let index = arguments.firstIndex(of: "--render-about") {
            let output = index + 1 < arguments.count
                ? URL(fileURLWithPath: arguments[index + 1])
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("echocap-about.png")
            MainActor.assumeIsolated {
                UIPreviewRenderer.renderAbout(to: output)
                print("已渲染关于页预览: \(output.path)")
            }
            return
        }

        if arguments.contains("--render-overlay"), let index = arguments.firstIndex(of: "--render-overlay") {
            let output = index + 1 < arguments.count
                ? URL(fileURLWithPath: arguments[index + 1])
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("echocap-overlay.png")
            let state: UIPreviewRenderer.OverlayState = arguments.contains("--state-banner") ? .banner : .captions
            MainActor.assumeIsolated {
                UIPreviewRenderer.renderOverlay(to: output, state: state)
                print("已渲染浮层预览: \(output.path)")
            }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Owns the app's lifecycle and the global keyboard shortcuts.
@available(macOS 26.0, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: AppController?
    private var menuBar: MenuBarController?
    /// Keeps the signal sources alive for the lifetime of the app.
    private var signalSources: [DispatchSourceSignal] = []


    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        self.controller = controller

        let menuBar = MenuBarController(controller: controller)
        self.menuBar = menuBar
        menuBar.install()

        SettingsWindowController.shared.configure(with: controller)
        controller.bootstrap()

        installGlobalMonitors()
        installSignalHandlers()

        // Nothing starts by itself: the user decides when to listen.
        controller.enterIdleState()
    }

    /// Offer to save the recording before the app goes away.
    ///
    /// The save panel and the summary run inside this call, so termination is
    /// deferred until the user is done rather than cutting them off.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = controller?.hasUnsavedTranscript ?? false
        controller?.log("退出请求：未保存的字幕=\(unsaved)")
        // Asking here does not work: AppKit tears the app down around this
        // call and a modal panel opened from here returns immediately without
        // ever being seen. Quitting from the menu asks first instead, before
        // termination begins.
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop(askToSave: false)
    }

    /// Shut down cleanly when the process is asked to terminate.
    ///
    /// Without this, a `kill` would leave the audio tap and its aggregate
    /// device behind, which makes the audio server progressively less willing
    /// to hand out new taps.
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            // Ignore the default disposition first: installing a dispatch
            // source does not stop the kernel from killing us, so without this
            // the handler never runs and the app dies without cleaning up.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.controller?.stop(askToSave: false)
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Global shortcuts

    /// Install the monitors that back `⌥` (rewind), `⌥F` (search), and `⇧` (drag).
    private func installGlobalMonitors() {
        // Holding ⌥ stacks the history boxes.
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        // ⌥F opens the search field.
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)

        // Global monitors fire on their own thread; the UI lives on the main actor.
        Task { @MainActor [weak self] in
            guard let controller = self?.controller else { return }
            controller.setHistoryVisible(option)

            // Holding ⇧ turns the overlay into something you can drag.
            if shift {
                controller.beginOverlayDrag()
            } else {
                controller.endOverlayDrag()
            }
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let characters = event.charactersIgnoringModifiers?.lowercased()
        let option = event.modifierFlags.contains(.option)

        Task { @MainActor [weak self] in
            guard let controller = self?.controller else { return }
            if option, characters == "f" {
                controller.presentSearch()
                return
            }
            if characters == "\u{1b}" { // Escape
                controller.dismissHistory()
            }
        }
    }
}
