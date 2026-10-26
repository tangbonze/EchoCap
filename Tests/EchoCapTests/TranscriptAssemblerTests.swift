import Testing
@testable import EchoCapCore

@Suite("识别结果分段")
struct TranscriptAssemblerTests {

    @Test("累积式结果返回当前分段的完整文字")
    func cumulativeResultsReturnSegmentText() {
        let assembler = TranscriptAssembler()
        var update = assembler.ingest(text: "Hello", isFinal: false)
        #expect(update.text == "Hello")
        #expect(update.isNewSegment)

        update = assembler.ingest(text: "Hello, world", isFinal: false)
        #expect(update.text == "Hello, world")
        #expect(update.isNewSegment == false)
        #expect(update.isFinal == false)
    }

    @Test("定稿后分段进入已提交区")
    func finalSegmentIsCommitted() {
        let assembler = TranscriptAssembler()
        _ = assembler.ingest(text: "First sentence.", isFinal: false)
        let update = assembler.ingest(text: "First sentence.", isFinal: true)
        #expect(update.isFinal)
        #expect(assembler.committedText == "First sentence.")
        #expect(assembler.volatileText.isEmpty)
    }

    @Test("新分段会关闭上一段")
    func newSegmentClosesPrevious() {
        let assembler = TranscriptAssembler()
        _ = assembler.ingest(text: "First part.", isFinal: false)
        let update = assembler.ingest(text: "Second part.", isFinal: false)
        #expect(update.isNewSegment)
        #expect(assembler.committedText == "First part.")
        #expect(assembler.volatileText == "Second part.")
    }

    @Test("识别器改口时保留修订后的文字")
    func revisionsReplaceEarlierText() {
        let assembler = TranscriptAssembler()
        _ = assembler.ingest(text: "EchoCab", isFinal: false)
        let update = assembler.ingest(text: "EchoCap.", isFinal: false)
        // 修订后的整段文字被替换，而不是把旧片段留下。
        #expect(update.text == "EchoCap.")
    }

    @Test("多段按时间顺序拼接")
    func segmentsJoinInOrder() {
        let assembler = TranscriptAssembler()
        _ = assembler.ingest(text: "One.", isFinal: true)
        _ = assembler.ingest(text: "Two.", isFinal: true)
        #expect(assembler.committedText == "One. Two.")
    }

    @Test("重置清空全部状态")
    func resetClearsEverything() {
        let assembler = TranscriptAssembler()
        _ = assembler.ingest(text: "Something", isFinal: true)
        assembler.reset()
        #expect(assembler.committedText.isEmpty)
        #expect(assembler.volatileText.isEmpty)
    }
}
