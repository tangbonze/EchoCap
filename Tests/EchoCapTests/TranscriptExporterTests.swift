import Testing
import Foundation
@testable import EchoCapCore

@Suite("字幕记录导出")
struct TranscriptExporterTests {

    private func boxes() -> [CaptionBox] {
        [
            CaptionBox(
                committedText: "The first five years improved by a factor of ten.",
                translation: "前五年提高了十倍。",
                sourceAppName: "Zoom",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastTextAt: Date(timeIntervalSince1970: 1_700_000_004)
            ),
            CaptionBox(
                committedText: "That is the whole point.",
                translation: "这就是重点。",
                createdAt: Date(timeIntervalSince1970: 1_700_000_010)
            ),
        ]
    }

    @Test("写 .md 得到带时间戳和译文的 Markdown")
    func writesMarkdown() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).md")
        try TranscriptExporter.write(boxes: boxes(), to: url)
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(text.hasPrefix("# 字幕记录"))
        #expect(text.contains("> 前五年提高了十倍。"))
        #expect(text.contains("**Zoom**"))
        try? FileManager.default.removeItem(at: url)
    }

    @Test("写 .txt 得到纯文本，不带 Markdown 记号")
    func writesPlainText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).txt")
        try TranscriptExporter.write(boxes: boxes(), to: url)
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(!text.contains("# 字幕记录"))
        #expect(!text.contains("> "))
        #expect(text.contains("The first five years improved by a factor of ten."))
        #expect(text.contains("[Zoom]"))
        try? FileManager.default.removeItem(at: url)
    }

    @Test("其它扩展名按纯文本处理")
    func unknownExtensionFallsBackToPlainText() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).log")
        try TranscriptExporter.write(boxes: boxes(), to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("# 字幕记录"))
        try? FileManager.default.removeItem(at: url)
    }
}
