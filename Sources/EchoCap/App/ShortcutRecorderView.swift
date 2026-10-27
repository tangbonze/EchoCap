import AppKit
import SwiftUI
import Carbon.HIToolbox
import EchoCapCore

/// A field that records the next key combination the user presses.
///
/// A plain `TextField` cannot do this: the keys are the value. So this is a
/// small `NSView` that becomes first responder, takes the next `keyDown`, and
/// hands back the virtual key code with the Carbon modifier mask the window
/// server needs for a global hot key.
struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: HotKeyShortcut

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField()
        field.shortcut = shortcut
        field.onChange = { newValue in
            shortcut = newValue
        }
        return field
    }

    func updateNSView(_ field: ShortcutRecorderField, context: Context) {
        if field.shortcut != shortcut, !field.isRecording {
            field.shortcut = shortcut
        }
    }
}

/// The actual control.
final class ShortcutRecorderField: NSView {

    var shortcut: HotKeyShortcut = .default {
        didSet { needsDisplay = true }
    }
    var onChange: ((HotKeyShortcut) -> Void)?

    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = isRecording ? "按下组合键…" : shortcut.displayString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isRecording
                ? NSColor.secondaryLabelColor
                : NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        text.draw(at: origin, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Escape leaves the shortcut as it was.
        if event.keyCode == UInt32(kVK_Escape), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            isRecording = false
            window?.makeFirstResponder(nil)
            return
        }

        let shortcut = HotKeyShortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: Self.carbonModifiers(from: event.modifierFlags)
        )
        // Without a modifier it would swallow a plain key everywhere.
        guard shortcut.isValid else {
            NSSound.beep()
            return
        }

        self.shortcut = shortcut
        isRecording = false
        window?.makeFirstResponder(nil)
        onChange?(shortcut)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }
}
