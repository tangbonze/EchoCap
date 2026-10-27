import AppKit
import Carbon.HIToolbox

/// A system-wide hot key.
///
/// `NSEvent.addGlobalMonitorForEvents` only sees keys when the app has been
/// granted Accessibility/Input Monitoring, and silently does nothing
/// otherwise. A Carbon hot key is registered with the window server instead:
/// it needs no permission and fires no matter which app is in front, which is
/// what a start/stop shortcut has to do.
final class GlobalHotKey: @unchecked Sendable {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onPress: @Sendable () -> Void

    /// - Parameters:
    ///   - keyCode: a `kVK_…` virtual key code.
    ///   - modifiers: Carbon modifier mask (`cmdKey`, `optionKey`, …).
    /// Whether the hot key was accepted by the window server.
    private(set) var isRegistered = false

    init(keyCode: UInt32, modifiers: UInt32, onPress: @escaping @Sendable () -> Void) {
        self.onPress = onPress

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                // 直接写 stderr，不经过任何 actor / 闭包，确认事件是否到达。
                FileHandle.standardError.write(Data("[hotkey] C handler fired\n".utf8))
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.onPress()
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandler
        )

        // 'ECHO' as a signature, so the id is unlikely to clash with anyone.
        let hotKeyID = EventHotKeyID(signature: OSType(0x4543_484F), id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        isRegistered = status == noErr
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
