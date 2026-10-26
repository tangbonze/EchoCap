import AppKit
import SwiftUI
import EchoCapCore

/// Renders the caption overlay to a PNG without touching the desktop.
///
/// Used to preview the overlay's appearance without needing the screen to be
/// unlocked — and without putting a window on top of the user's work.
@MainActor
enum OverlayPreviewRenderer {

    /// Render a sample overlay to `url`.
    static func render(to url: URL, size: CGSize = CGSize(width: 1100, height: 260)) {
        let settings = AppSettings.shared
        settings.fontSize = 28
        settings.boxOpacity = 0.62
        settings.showBothLanguages = true
        settings.showSourceAppName = true

        let model = OverlayModel(settings: settings)

        // A representative set of boxes: live caption on top, history below.
        let live = CaptionBox(
            committedText: "The quick brown fox jumps over the lazy dog",
            translation: "敏捷的棕色狐狸跳过了那只懒狗",
            sourceAppName: "Zoom"
        )
        let history = CaptionBox(
            committedText: "Let me share my screen so everyone can follow along.",
            translation: "我来共享屏幕，这样大家都能跟上。",
            sourceAppName: "Zoom",
            createdAt: Date().addingTimeInterval(-6)
        )
        model.liveBox = live
        model.historyBoxes = [history]
        model.isShowingHistory = true

        let view = CaptionOverlayView(model: model)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        // Force SwiftUI to lay out and draw.
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
