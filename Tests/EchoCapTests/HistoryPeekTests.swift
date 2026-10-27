import Testing
@testable import EchoCapCore

@Suite("历史预览触发条件")
struct HistoryPeekTests {

    @Test("单按 ⌥ 显示历史")
    func optionAloneShows() {
        #expect(HistoryPeek.shouldShow(option: true, command: false))
    }

    @Test("⌥⌘S 是快捷键，不显示历史")
    func optionCommandDoesNotShow() {
        #expect(!HistoryPeek.shouldShow(option: true, command: true))
    }

    @Test("没有 ⌥ 就不显示")
    func noOptionDoesNotShow() {
        #expect(!HistoryPeek.shouldShow(option: false, command: false))
        #expect(!HistoryPeek.shouldShow(option: false, command: true))
    }
}
