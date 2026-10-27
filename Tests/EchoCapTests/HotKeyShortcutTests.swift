import Testing
import Foundation
import Carbon.HIToolbox
@testable import EchoCapCore

@Suite("快捷键设置")
struct HotKeyShortcutTests {

    @Test("默认是 ⌥⌘S")
    func defaultShortcut() {
        #expect(HotKeyShortcut.default.displayString == "⌥⌘S")
        #expect(HotKeyShortcut.default.isValid)
    }

    @Test("符号顺序固定为 ⌃⌥⇧⌘")
    func displayOrder() {
        let all = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        #expect(all.displayString == "⌃⌥⇧⌘K")
    }

    @Test("没有修饰键的组合不合法")
    func requiresModifier() {
        let bare = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: 0)
        #expect(bare.isValid == false)
        #expect(bare.displayString == "S")
    }

    @Test("只按 shift 也不算，避免吞掉大写字母")
    func shiftAloneIsNotEnough() {
        let shifted = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_S),
            carbonModifiers: UInt32(shiftKey)
        )
        #expect(shifted.isValid == false)
    }

    @Test("功能键有名字，陌生键退化成键码")
    func keyNames() {
        #expect(HotKeyShortcut.keyName(for: UInt32(kVK_F5)) == "F5")
        #expect(HotKeyShortcut.keyName(for: UInt32(kVK_Space)) == "空格")
        #expect(HotKeyShortcut.keyName(for: 300).hasPrefix("键码"))
    }

    @Test("设置里能存取自定义快捷键")
    func storedShortcutRoundTrips() {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: defaults)

        #expect(settings.keyboardShortcut == .default)

        let custom = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_J),
            carbonModifiers: UInt32(controlKey | optionKey)
        )
        settings.keyboardShortcut = custom
        #expect(settings.keyboardShortcut == custom)
        #expect(settings.keyboardShortcut.displayString == "⌃⌥J")
    }

    @Test("存了不合法的组合时退回默认")
    func invalidStoredValueFallsBack() {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(0, forKey: "shortcutModifiers")
        defaults.set(Int(kVK_ANSI_S), forKey: "shortcutKeyCode")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.keyboardShortcut == .default)
    }
}
