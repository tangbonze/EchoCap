import AppKit
import SwiftUI
import EchoCapCore

/// The always-on-top caption overlay.
///
/// Three behaviours define this window and are the reason it exists:
///
/// - It never swallows clicks, so you can keep working in the app underneath.
/// - The part of the caption under your pointer dissolves away, so the text
///   never covers what you are reading or writing.
/// - Holding `⇧` turns it into something you can drag.
final class CaptionOverlayWindow: NSPanel {

    /// Reports a drag so the app can persist the overlay position.
    var onPositionChanged: (() -> Void)?

    private var dragOffset: NSPoint = .zero
    private var isDragging = false

    init(model: OverlayModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none

        let host = NSHostingView(rootView: CaptionOverlayView(model: model))
        // Let AppKit size the hosting view to the window. Turning off the
        // autoresizing translation on the content view itself leaves it with
        // no size, and the overlay then draws nothing at all.
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    /// Reposition the overlay to the centre of the main screen.
    func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.18
        )
        setFrameOrigin(origin)
        onPositionChanged?()
    }

    /// Restore a previously saved position.
    func restorePosition(_ origin: NSPoint) {
        setFrameOrigin(origin)
    }

    // MARK: - Dragging

    /// Begin a drag from the current pointer position.
    ///
    /// The overlay normally ignores mouse events so clicks reach the app
    /// underneath. While `⇧` is held we temporarily accept them so the
    /// overlay can be moved.
    func beginDragFromCurrentPointer() {
        guard !isDragging else { return }
        isDragging = true
        let mouse = NSEvent.mouseLocation
        dragOffset = NSPoint(x: mouse.x - frame.origin.x, y: mouse.y - frame.origin.y)
        ignoresMouseEvents = false
    }

    func updateDrag() {
        guard isDragging else { return }
        let mouse = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y))
    }

    func endDrag() {
        guard isDragging else { return }
        isDragging = false
        // Restore click-through unless the user turned it off.
        ignoresMouseEvents = true
        onPositionChanged?()
    }
}
