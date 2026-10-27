import Testing
import Foundation
@testable import EchoCapCore

@Suite("字幕分页与历史")
struct CaptionPipelineTests {

    private func makeSettings() -> AppSettings {
        let name = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: defaults)
        settings.linesPerBox = 3
        settings.fontSize = 28
        settings.historyTimeout = 30
        return settings
    }

    @Test("最终文本进入字幕框")
    func committedTextBecomesVisible() {        let pipeline = CaptionPipeline(settings: makeSettings())
        pipeline.ingest(text: "Hello world", segmentID: 1, isFinal: true)
        #expect(pipeline.liveBox?.displayText == "Hello world")
    }

    @Test("未定稿文本随识别器修订而更新")
    func volatileTextFollowsRecogniserRevisions() {
        let pipeline = CaptionPipeline(settings: makeSettings())
        // 识别器逐词吐出同一分段的累积文字。
        pipeline.ingest(text: "Hello", segmentID: 1, isFinal: false)
        #expect(pipeline.liveBox?.displayText == "Hello")
        pipeline.ingest(text: "Hello, world", segmentID: 1, isFinal: false)
        #expect(pipeline.liveBox?.displayText == "Hello, world")
        // 改口时整段被替换，不留下旧片段。
        pipeline.ingest(text: "Hello, word", segmentID: 1, isFinal: false)
        #expect(pipeline.liveBox?.displayText == "Hello, word")
    }

    @Test("定稿后文字转入已提交区")
    func finalTextBecomesCommitted() {
        let pipeline = CaptionPipeline(settings: makeSettings())
        pipeline.ingest(text: "Hello", segmentID: 1, isFinal: false)
        pipeline.ingest(text: "Hello, world", segmentID: 1, isFinal: true)
        #expect(pipeline.liveBox?.committedText == "Hello, world")
        #expect(pipeline.liveBox?.volatileText.isEmpty == true)
    }

    @Test("新分段会提交上一段")
    func newSegmentCommitsPrevious() {
        let pipeline = CaptionPipeline(settings: makeSettings())
        pipeline.ingest(text: "First sentence.", segmentID: 1, isNewSegment: false, isFinal: false)
        pipeline.ingest(text: "Second sentence.", segmentID: 2, isNewSegment: true, isFinal: false)
        #expect(pipeline.liveBox?.committedText == "First sentence.")
        #expect(pipeline.liveBox?.displayText == "First sentence. Second sentence.")
    }

    @Test("超出行数上限时分页成多个字幕框")
    func overflowPaginatesIntoSeparateBoxes() {
        let settings = makeSettings()
        settings.linesPerBox = 2
        let pipeline = CaptionPipeline(settings: settings)

        // 长到必然超过两行的文本。
        let long = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 8)
            .trimmingCharacters(in: .whitespaces)
        let totalLines = TextMeasurer.lineCount(
            text: long,
            fontSize: settings.fontSize,
            width: pipeline.measurementWidth
        )
        #expect(totalLines > settings.linesPerBox, "测试文本本身应当超过行数上限")

        pipeline.ingest(text: long, segmentID: 1, isFinal: true)

        #expect(pipeline.historyBoxes.count > 0, "长文本应当被分页")
        for box in pipeline.historyBoxes {
            let lines = TextMeasurer.lineCount(
                text: box.displayText,
                fontSize: settings.fontSize,
                width: pipeline.measurementWidth
            )
            #expect(lines <= settings.linesPerBox, "每个字幕框都不应超过行数上限")
        }
        // 所有文字都应保留下来。
        let rejoined = pipeline.historyBoxes.map(\.displayText).joined(separator: " ")
        #expect(rejoined.contains("lazy dog"))
    }

    @Test("搜索能命中历史字幕")
    func searchFindsBoxes() {
        let pipeline = CaptionPipeline(settings: makeSettings())
        pipeline.ingest(text: "the meeting starts now", segmentID: 1, isFinal: true)
        pipeline.sealCurrentBox()
        pipeline.ingest(text: "lunch is at noon", segmentID: 2, isFinal: true)
        pipeline.sealCurrentBox()

        #expect(pipeline.search("meeting").count == 1)
        #expect(pipeline.search("lunch").count == 1)
        #expect(pipeline.search("nothing here").count == 0)
        #expect(pipeline.search("").count == 2)
    }

    @Test("静默超时后清空历史")
    func historyTimeoutClearsHistory() {
        let settings = makeSettings()
        settings.historyTimeout = 30
        let pipeline = CaptionPipeline(settings: settings)
        pipeline.ingest(text: "something happened", segmentID: 1, isFinal: true)
        pipeline.sealCurrentBox()
        // 5 秒后还没超时，60 秒后已经超时。
        #expect(pipeline.shouldClearHistory(now: Date().addingTimeInterval(5)) == false)
        #expect(pipeline.shouldClearHistory(now: Date().addingTimeInterval(60)) == true)
    }

    @Test("淡出只由新文字触发")
    func fadeOnlyCountsNewText() {
        let settings = makeSettings()
        settings.fadeDelay = 4
        let pipeline = CaptionPipeline(settings: settings)
        pipeline.ingest(text: "still talking", segmentID: 1, isFinal: false)
        #expect(pipeline.shouldFadeLiveBox(now: Date().addingTimeInterval(1)) == false)
        #expect(pipeline.shouldFadeLiveBox(now: Date().addingTimeInterval(10)) == true)
    }
    @Test("窗口变窄后分页跟着变窄")
    func paginationFollowsMeasurementWidth() {
        let settings = makeSettings()
        settings.linesPerBox = 2

        let wide = CaptionPipeline(settings: settings)
        wide.measurementWidth = 1100
        let narrow = CaptionPipeline(settings: settings)
        narrow.measurementWidth = 420

        let text = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 6)
            .trimmingCharacters(in: .whitespaces)

        wide.ingest(text: text, segmentID: 1, isFinal: true)
        narrow.ingest(text: text, segmentID: 1, isFinal: true)

        // 同样一段话，窄窗口要多分几屏。
        #expect(narrow.historyBoxes.count > wide.historyBoxes.count)
        for box in narrow.historyBoxes {
            let lines = TextMeasurer.lineCount(
                text: box.displayText,
                fontSize: settings.fontSize,
                width: narrow.measurementWidth
            )
            #expect(lines <= settings.linesPerBox)
        }
    }

}
