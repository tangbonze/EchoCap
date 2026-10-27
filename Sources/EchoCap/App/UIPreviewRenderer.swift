import AppKit
import SwiftUI
import EchoCapCore

/// Renders parts of the UI to PNG without putting anything on the desktop.
///
/// Used to preview the settings panel and the overlay when the screen is
/// locked, or simply to produce documentation images.
@MainActor
enum UIPreviewRenderer {

    /// Render the settings window's "关于" tab.
    static func renderAbout(to url: URL, size: CGSize = CGSize(width: 640, height: 760)) {
        let settings = AppSettings.shared
        let model = SettingsViewModel(settings: settings, onChange: {}, initialTab: .about)
        let view = SettingsView(model: model, settings: settings)
        render(view, to: url, size: size)
    }

    /// Render the settings window's first tab, for checking the controls
    /// without opening a window.
    static func renderSettings(to url: URL, size: CGSize = CGSize(width: 640, height: 580)) {
        let settings = AppSettings.shared
        let model = SettingsViewModel(settings: settings, onChange: {}, initialTab: .appearance)
        let view = SettingsView(model: model, settings: settings)
        render(view, to: url, size: size)
    }

    /// Render the caption overlay in one of its states.
    static func renderOverlay(
        to url: URL,
        state: OverlayState = .captions,
        size: CGSize = CGSize(width: 1100, height: 260)
    ) {
        let settings = AppSettings.shared
        settings.fontSize = 28
        settings.boxOpacity = 0.62
        settings.showBothLanguages = true
        settings.showSourceAppName = true

        let model = OverlayModel(settings: settings)
        switch state {
        case .captions:
            model.liveBox = CaptionBox(
                committedText: "The quick brown fox jumps over the lazy dog",
                translation: "敏捷的棕色狐狸跳过了那只懒狗",
                sourceAppName: "Zoom"
            )
            model.historyBoxes = [CaptionBox(
                committedText: "Let me share my screen so everyone can follow along.",
                translation: "我来共享屏幕，这样大家都能跟上。",
                sourceAppName: "Zoom",
                createdAt: Date().addingTimeInterval(-6)
            )]
        case .banner:
            model.banner = OverlayBanner(
                kind: .error,
                title: "没能开始聆听系统音频",
                detail: "系统可能没有可用的音频输出设备。可先在菜单里改用麦克风。"
            )
        case .waiting:
            model.banner = OverlayBanner(
                kind: .info,
                title: "正在聆听……",
                detail: "播放点什么，字幕就会出现在这里。"
            )
        }

        let view = CaptionOverlayView(model: model)
        render(view, to: url, size: size)
    }

    /// The state to show in an overlay preview.
    enum OverlayState {
        case captions
        case banner
        case waiting
    }

    /// Render a SwiftUI view into a PNG file.
    private static func render(_ view: some View, to url: URL, size: CGSize) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
