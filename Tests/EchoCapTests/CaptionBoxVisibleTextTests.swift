import Testing
import Foundation
@testable import EchoCapCore

@Suite("字幕框可见行数")
struct CaptionBoxVisibleTextTests {

    /// A box whose text is far longer than the line budget.
    private func longBox(_ text: String) -> CaptionBox {
        var box = CaptionBox()
        box.setCommitted(text)
        return box
    }

    @Test("短文本原样返回")
    func shortTextIsUntouched() {
        let box = longBox("Hello world")
        #expect(box.visibleText(maxLines: 4, fontSize: 28, width: 1000) == "Hello world")
    }

    @Test("超长英文被裁到最多 4 行")
    func longEnglishIsClippedToFourLines() {
        let text = String(
            repeating: "the quick brown fox jumps over the lazy dog ",
            count: 20
        ).trimmingCharacters(in: .whitespaces)

        let visible = longBox(text).visibleText(maxLines: 4, fontSize: 28, width: 1000)
        let lines = TextMeasurer.lineCount(text: visible, fontSize: 28, width: 1000)

        #expect(lines <= 4)
        // 保留的是最新的内容（文本尾部），不是开头。
        #expect(visible.hasSuffix("lazy dog"))
        #expect(!visible.hasPrefix("the quick"))
    }

    @Test("无空格的中文同样被裁到 4 行")
    func longChineseIsClippedToo() {
        let text = String(repeating: "这是一段很长的中文字幕内容用于测试换行裁剪", count: 12)

        let visible = longBox(text).visibleText(maxLines: 4, fontSize: 28, width: 1000)
        let lines = TextMeasurer.lineCount(text: visible, fontSize: 28, width: 1000)

        #expect(lines <= 4)
        #expect(!visible.isEmpty)
        #expect(text.hasSuffix(visible))
    }

    @Test("定稿译文会顶掉实时译文，不重复拼接")
    func finalTranslationReplacesVolatile() {
        var box = CaptionBox()
        box.setVolatile("Live subtitles work.")
        box.setVolatileTranslation("实时字幕可用。")
        #expect(box.displayTranslation == "实时字幕可用。")

        box.setTranslation("实时字幕可以工作。")
        // 只保留定稿译文：两者不会拼在一起。
        #expect(box.displayTranslation == "实时字幕可以工作。")
    }
}
