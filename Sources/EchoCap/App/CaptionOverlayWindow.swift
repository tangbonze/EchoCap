import AppKit
import SwiftUI
import EchoCapCore

/// The always-on-top caption overlay.
///
/// Two behaviours define this window and are the reason it exists:
///
/// - It never swallows clicks, so you can keep working in the app underneath.
/// - Holding `⇧` turns it into something you can drag.
///
/// ## Moving and resizing
///
/// A window that ignores mouse events cannot be dragged or resized with the
/// mouse, and swallowing every click would defeat the point of an overlay you
/// read *while* working. So there is an explicit **layout editing** mode: while
/// it is on the window takes clicks and you can drag it anywhere, or drag its
/// edges and corners to resize. While it is off the window is click-through
/// again, and only `⇧`-dragging moves it.
///
/// The dragging and resizing are implemented by hand rather than left to
/// AppKit: a borderless window gets no resize handles from `.resizable`, so the
/// edges are hit-tested in `OverlayContainerView` instead.
final class CaptionOverlayWindow: NSPanel {

    /// Reports a move or a resize so the app can persist the geometry.
    var onGeometryChanged: (() -> Void)?

    /// Default size before the user has resized anything.
    static let defaultSize = NSSize(width: 1100, height: 260)

    /// Smallest useful size — one short caption and its translation.
    static let minimumSize = NSSize(width: 360, height: 96)

    /// How close to an edge counts as grabbing it, in points.
    static let gripThickness: CGFloat = 18

    private var dragOffset: NSPoint = .zero
    private var isDragging = false
    private var container: OverlayContainerView?

    /// Whether the overlay currently accepts mouse input for layout editing.
    private(set) var isEditingLayout = false

    init(model: OverlayModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
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
        minSize = Self.minimumSize

        let host = NSHostingView(rootView: CaptionOverlayView(model: model))
        host.autoresizingMask = [.width, .height]

        let container = OverlayContainerView()
        container.hostingView = host
        container.frame = NSRect(origin: .zero, size: Self.defaultSize)
        host.frame = container.bounds
        container.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.owner = self
        contentView = container
        self.container = container
    }

    // MARK: - Layout editing

    /// Turn mouse interaction on or off.
    ///
    /// While on, the overlay behaves like a normal window: it takes clicks, can
    /// be moved by dragging it, and resized from its edges and corners. While
    /// off it is click-through and only `⇧`-dragging moves it.
    func setLayoutEditing(_ editing: Bool) {
        isEditingLayout = editing
        ignoresMouseEvents = !editing
        isMovableByWindowBackground = false
        if editing {
            orderFrontRegardless()
        }
        if let container {
            invalidateCursorRects(for: container)
        }
    }

    /// Restore the default size, keeping the top edge where it is.
    func resetSize() {
        var newFrame = frame
        newFrame.size = Self.defaultSize
        newFrame.origin.y = frame.maxY - Self.defaultSize.height
        setFrame(newFrame, display: true)
        onGeometryChanged?()
    }

    // MARK: - Geometry

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
        onGeometryChanged?()
    }

    /// Restore a previously saved position.
    func restorePosition(_ origin: NSPoint) {
        setFrameOrigin(origin)
    }

    /// Restore a previously saved size, clamped to what the screen allows.
    func restoreSize(_ size: NSSize) {
        var newSize = size
        newSize.width = max(Self.minimumSize.width, newSize.width)
        newSize.height = max(Self.minimumSize.height, newSize.height)
        if let screen = NSScreen.main {
            newSize.width = min(newSize.width, screen.visibleFrame.width)
            newSize.height = min(newSize.height, screen.visibleFrame.height)
        }

        var newFrame = frame
        newFrame.size = newSize
        // Keep the top-left corner fixed so the caption does not jump.
        newFrame.origin.y = frame.maxY - newSize.height
        setFrame(newFrame, display: true)
    }

    /// Called for both moves and resizes; the app persists what changed.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        onGeometryChanged?()
    }

    // MARK: - Dragging with ⇧

    /// Begin a drag from the current pointer position.
    ///
    /// Used when `⇧` is held while the window is click-through, so the overlay
    /// still accepts the drag without taking clicks the rest of the time.
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
        // Back to click-through unless the user is editing the layout.
        ignoresMouseEvents = !isEditingLayout
        onGeometryChanged?()
    }
}

// MARK: - Interaction

/// The window's content view. Owns the SwiftUI view and turns mouse drags into
/// window moves or resizes.
final class OverlayContainerView: NSView {

    weak var owner: CaptionOverlayWindow?
    var hostingView: NSView?

    /// Which edges the current drag started on; empty means "move the window".
    private var activeEdges: EdgeSet = []
    private var initialFrame: NSRect = .zero
    private var initialMouse: NSPoint = .zero

    struct EdgeSet: OptionSet {
        let rawValue: Int
        static let left = EdgeSet(rawValue: 1 << 0)
        static let right = EdgeSet(rawValue: 1 << 1)
        static let bottom = EdgeSet(rawValue: 1 << 2)
        static let top = EdgeSet(rawValue: 1 << 3)
    }

    /// Let the window handle every hit: the caption never needs clicks itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let owner, owner.isEditingLayout else { return nil }
        return self
    }

    // MARK: Cursors

    override func resetCursorRects() {
        super.resetCursorRects()
        guard owner?.isEditingLayout == true else { return }
        let grip = CaptionOverlayWindow.gripThickness
        let b = bounds
        let corners: [(NSRect, NSCursor)] = [
            (NSRect(x: b.minX, y: b.minY, width: grip, height: grip), .crosshair),
            (NSRect(x: b.maxX - grip, y: b.minY, width: grip, height: grip), .crosshair),
            (NSRect(x: b.minX, y: b.maxY - grip, width: grip, height: grip), .crosshair),
            (NSRect(x: b.maxX - grip, y: b.maxY - grip, width: grip, height: grip), .crosshair),
            (NSRect(x: b.minX, y: b.minY, width: grip, height: b.height), .resizeLeftRight),
            (NSRect(x: b.maxX - grip, y: b.minY, width: grip, height: b.height), .resizeLeftRight),
            (NSRect(x: b.minX, y: b.minY, width: b.width, height: grip), .resizeUpDown),
            (NSRect(x: b.minX, y: b.maxY - grip, width: b.width, height: grip), .resizeUpDown),
        ]
        for (rect, cursor) in corners {
            addCursorRect(rect, cursor: cursor)
        }
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func edges(at point: NSPoint) -> EdgeSet {
        let grip = CaptionOverlayWindow.gripThickness
        let b = bounds
        var edges: EdgeSet = []
        if point.x <= b.minX + grip { edges.insert(.left) }
        if point.x >= b.maxX - grip { edges.insert(.right) }
        if point.y <= b.minY + grip { edges.insert(.bottom) }
        if point.y >= b.maxY - grip { edges.insert(.top) }
        return edges
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, owner?.isEditingLayout == true else { return }
        let local = convert(event.locationInWindow, from: nil)
        activeEdges = edges(at: local)
        initialFrame = window.frame
        initialMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, owner?.isEditingLayout == true else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - initialMouse.x
        let dy = mouse.y - initialMouse.y

        guard !activeEdges.isEmpty else {
            window.setFrameOrigin(
                NSPoint(x: initialFrame.origin.x + dx, y: initialFrame.origin.y + dy)
            )
            return
        }

        let minimum = CaptionOverlayWindow.minimumSize
        var frame = initialFrame
        if activeEdges.contains(.left) {
            let newWidth = max(minimum.width, initialFrame.width - dx)
            frame.origin.x = initialFrame.maxX - newWidth
            frame.size.width = newWidth
        }
        if activeEdges.contains(.right) {
            frame.size.width = max(minimum.width, initialFrame.width + dx)
        }
        if activeEdges.contains(.bottom) {
            let newHeight = max(minimum.height, initialFrame.height - dy)
            frame.origin.y = initialFrame.maxY - newHeight
            frame.size.height = newHeight
        }
        if activeEdges.contains(.top) {
            frame.size.height = max(minimum.height, initialFrame.height + dy)
        }
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges = []
        owner?.onGeometryChanged?()
    }

    /// AppKit sends the drag to the window unless the view has focus; ask for
    /// it so `mouseDragged` keeps coming.
    override var acceptsFirstResponder: Bool { true }
}
