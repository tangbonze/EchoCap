import AppKit
import AVFoundation
import Speech
import Translation
import NaturalLanguage
import EchoCapCore

/// Wires the whole pipeline together: capture → recognise → translate → display.
///
/// ```text
/// system audio tap ─┐
///                   ├→ 16 kHz mono ─→ Speech ─→ translation ─→ caption boxes ─→ overlay
/// microphone ───────┘
/// ```
@available(macOS 26.0, *)
@MainActor
final class AppController {

    // MARK: - Collaborators

    let settings = AppSettings.shared
    let pipeline: CaptionPipeline
    let overlayModel: OverlayModel

    private let overlay: CaptionOverlayWindow
    private let systemCapture = HelperAudioCapture()
    private let microphoneCapture = MicrophoneCapture()
    private let speech = SpeechEngine()
    private let translation = TranslationService()
    private let assembler = TranscriptAssembler()
    private let languageIdentifier = NLLanguageRecognizer()

    /// Timer that fades the overlay and prunes the history stack.
    private var displayTimer: Timer?

    /// Timer that watches the pointer so captions can dissolve under it.
    private var pointerTimer: Timer?

    /// The language the recogniser is currently using.
    private var activeRecognitionLanguage: Locale?

    /// The translation target in effect for this session.
    private var activeTranslationTarget: String?

    /// Cached source language for translation.
    private var detectedSourceLanguage: Locale.Language?

    /// Whether the app is currently capturing and recognising.
    private(set) var isRunning = false

    /// Status shown in the menu bar.
    private(set) var statusText: String = "已就绪"
    private(set) var lastError: String?

    /// When set, every recognised line is printed to stderr. Useful for
    /// verifying the pipeline from a terminal.
    private let diagnosticLog: Bool

    /// Total number of audio samples handed to the recogniser.
    private var receivedSampleCount = 0
    /// When the sample count was last reported.
    private var lastSampleReport = Date()

    /// Language override given on the command line, e.g. `--lang en-US`.
    static var commandLineLanguage: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--lang"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Audio source given on the command line, e.g. `--source microphone`.
    static var commandLineSource: AudioSource? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--source"), index + 1 < arguments.count else {
            return nil
        }
        return AudioSource(rawValue: arguments[index + 1])
    }

    /// Translation target given on the command line, e.g. `--translate zh-Hans`.
    static var commandLineTranslation: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--translate"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Print a diagnostic line to stderr when diagnostic logging is on.
    func log(_ message: String) {
        guard diagnosticLog else { return }
        FileHandle.standardError.write(Data("[echocap] \(message)\n".utf8))
    }

    init(diagnosticLog: Bool = CommandLine.arguments.contains("--log")) {
        self.diagnosticLog = diagnosticLog
        pipeline = CaptionPipeline(settings: settings)
        overlayModel = OverlayModel(settings: settings)
        overlay = CaptionOverlayWindow(model: overlayModel)

        overlay.onPositionChanged = { [weak self] in
            guard let self else { return }
            let origin = self.overlay.frame.origin
            self.settings.overlayOrigin = "\(origin.x),\(origin.y)"
        }
    }

    // MARK: - Setup

    /// Prepare the UI. Called once at launch.
    func bootstrap() {
        overlay.orderFrontRegardless()
        if let origin = settings.overlayOrigin {
            let parts = origin.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                overlay.restorePosition(NSPoint(x: parts[0], y: parts[1]))
            } else {
                overlay.resetPosition()
            }
        } else {
            overlay.resetPosition()
        }

        startDisplayTimer()
        startPointerTimer()
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshDisplay()
        }
        RunLoop.main.add(displayTimer!, forMode: .common)
    }

    private func startPointerTimer() {
        pointerTimer?.invalidate()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updatePointer()
        }
        RunLoop.main.add(pointerTimer!, forMode: .common)
    }

    /// Track the pointer so the caption can dissolve under it.
    private func updatePointer() {
        guard settings.fadeAwayUnderPointer else {
            overlayModel.pointerLocation = nil
            return
        }
        let mouse = NSEvent.mouseLocation
        guard overlay.frame.contains(mouse) else {
            overlayModel.pointerLocation = nil
            return
        }
        let local = overlay.convertPoint(fromScreen: mouse)
        overlayModel.pointerMoved(to: local)
    }

    // MARK: - Start / Stop

    /// Begin capturing and captioning.
    func start() async {
        guard !isRunning else { return }
        userPaused = false

        // Recogniser language.
        let recognitionLocale: Locale?
        if let override = Self.commandLineLanguage {
            recognitionLocale = Locale(identifier: override)
        } else if let id = settings.recognitionLanguage {
            recognitionLocale = LanguageCatalog.language(for: id)?.locale ?? Locale(identifier: id)
        } else {
            recognitionLocale = nil
        }
        activeRecognitionLanguage = recognitionLocale

        // Command-line overrides apply to this run only; they must not be
        // written back into the user's settings.
        let source = Self.commandLineSource ?? settings.source
        let translationTarget = Self.commandLineTranslation ?? settings.translationTarget

        activeTranslationTarget = translationTarget
        if Self.commandLineTranslation != nil {
            settings.showBothLanguages = true
        }

        // Install the callbacks before starting, so no result is missed.
        speech.callbacks.onResult = { [weak self] text, isFinal, rangeStart in
            // The recogniser reports on its own task; the UI lives on the main actor.
            Task { @MainActor [weak self] in
                self?.handleRecognition(text: text, isFinal: isFinal, rangeStart: rangeStart)
            }
        }

        do {
            try await speech.start(locale: recognitionLocale)
        } catch {
            lastError = error.localizedDescription
            statusText = "识别引擎启动失败"
            log("识别引擎启动失败: \(error.localizedDescription)")
            overlayModel.banner = OverlayBanner(
                kind: .error,
                title: "语音识别引擎没能启动",
                detail: error.localizedDescription
            )
            return
        }
        log("识别引擎已就绪，语言=\(speech.activeLocale?.identifier ?? "未知")")

        // Configure translation.
        log("准备配置翻译…")
        await configureTranslation(recognitionLocale: recognitionLocale, target: translationTarget)
        log("翻译配置完成")

        // Audio source.
        do {
            switch source {
            case .systemAudio:
                systemCapture.onSamples = { [weak self] samples in
                    Task { @MainActor [weak self] in
                        self?.speech.feed(samples: samples)
                        self?.receivedSampleCount += samples.count
                    }
                }
                systemCapture.onFailure = { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.log("采集失败: \(message)")
                    }
                }
                try await systemCapture.start()
            case .microphone:
                microphoneCapture.onSamples = { [weak self] samples in
                    self?.speech.feed(samples: samples)
                }
                try microphoneCapture.start()
            }
        } catch {
            lastError = error.localizedDescription
            statusText = "音频采集失败"
            let hint = (error as? HelperAudioCapture.CaptureError)?.recoveryHint
            log("音频采集失败: \(error.localizedDescription)\(hint.map { " — " + $0 } ?? "")")
            overlayModel.banner = OverlayBanner(
                kind: .error,
                title: "没能开始聆听系统音频",
                detail: hint ?? error.localizedDescription
            )
            await speech.finish()
            // The audio server sometimes recovers on its own — for instance
            // when the machine wakes up. Try again shortly.
            scheduleRetry()
            return
        }

        log("采集已启动: \(source.displayName)")
        overlayModel.banner = OverlayBanner(
            kind: .info,
            title: "正在聆听……",
            detail: "播放点什么，字幕就会出现在这里。"
        )
        isRunning = true
        receivedSampleCount = 0
        statusText = "正在聆听"
        lastError = nil
    }

    /// Stop capturing. The overlay keeps its last caption until it fades.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        userPaused = true
        statusText = "已暂停"
        systemCapture.stop()
        microphoneCapture.stop()
        speech.stop()
    }

    /// Toggle between running and paused.
    func toggle() async {
        if isRunning { stop() } else { await start() }
    }

    /// Retry the capture after a failure, unless the user paused meanwhile.
    private func scheduleRetry() {
        guard !isRunning else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !self.isRunning, !self.userPaused else { return }
            self.log("重试采集…")
            await self.start()
        }
    }

    /// Set when the user explicitly pauses, so a failed capture does not
    /// restart behind their back.
    private var userPaused = false

    /// Switch the audio source, restarting capture.
    func switchSource(_ source: AudioSource) async {
        guard settings.source != source else { return }
        settings.source = source
        let wasRunning = isRunning
        stop()
        if wasRunning { await start() }
    }

    /// Restart recognition with a new language or translation target.
    func reconfigure() async {
        let wasRunning = isRunning
        stop()
        assembler.reset()
        pipeline.reset()
        if wasRunning { await start() }
    }

    // MARK: - Translation

    private func configureTranslation(recognitionLocale: Locale?, target targetID: String?) async {
        guard let targetID,
              let target = LanguageCatalog.language(for: targetID) else {
            await translation.reset()
            return
        }

        // The source is the language we are recognising, when known.
        let source: Locale.Language
        if let recognitionLocale {
            source = recognitionLocale.language
        } else if let detected = detectedSourceLanguage {
            source = detected
        } else {
            // Fall back to English until we have heard something.
            source = Locale.Language(identifier: "en")
        }

        _ = await translation.configure(source: source, target: target.language)
    }
    // MARK: - Recognition handling

    private func handleRecognition(text: String, isFinal: Bool, rangeStart: Double) {
        // Turn the recogniser's cumulative text into a segment update.
        if diagnosticLog {
            log("RAW final=\(isFinal) range=\(String(format: "%.4f", rangeStart)) len=\(text.count) tail=\(text.suffix(28))")
        }
        let update = assembler.ingest(text: text, isFinal: isFinal)

        // Work out the source language for translation using on-device
        // language identification.
        if activeTranslationTarget != nil, detectedSourceLanguage == nil {
            if let detected = detectLanguage(of: update.text) {
                detectedSourceLanguage = detected
                Task { await configureTranslation(
                    recognitionLocale: activeRecognitionLanguage,
                    target: activeTranslationTarget
                ) }
            }
        }

        pipeline.ingest(
            text: update.text,
            segmentID: update.segmentIndex,
            isNewSegment: update.isNewSegment,
            isFinal: update.isFinal
        )

        if diagnosticLog {
            let kind = update.isFinal ? "定稿" : "实时"
            let shown = pipeline.liveBox?.displayText ?? update.text
            log("\(kind): \(shown)")
        }

        // Translate a segment once the recogniser has settled on it.
        if update.isFinal, activeTranslationTarget != nil {
            let source = update.text
            Task { [weak self] in
                guard let self else { return }
                if let translated = await self.translation.translate(source) {
                    await MainActor.run {
                        self.pipeline.setTranslation(translated, isFinal: true)
                        self.log("译文: \(translated)")
                    }
                } else {
                    await MainActor.run { self.log("译文失败（语言组合可能不支持）") }
                }
            }
        }

        refreshDisplay()
    }

    /// Identify the language of `text` on-device.
    private func detectLanguage(of text: String) -> Locale.Language? {
        guard text.count >= 8 else { return nil }
        languageIdentifier.processString(text)
        defer { languageIdentifier.reset() }
        guard let dominant = languageIdentifier.dominantLanguage else { return nil }
        return Locale.Language(identifier: dominant.rawValue)
    }

    // MARK: - Display

    private func refreshDisplay() {
        let now = Date()

        if diagnosticLog, now.timeIntervalSince(lastSampleReport) > 2 {
            lastSampleReport = now
            let seconds = Double(receivedSampleCount) / 16000.0
            log("已收到 \(receivedSampleCount) 个采样（约 \(String(format: "%.2f", seconds)) 秒音频）")
        }

        if pipeline.shouldClearHistory(now: now) {
            pipeline.clearHistory()
        }

        let visible = pipeline.visibleBoxes(now: now)
        let live = visible.first { $0.isLive }
        let history = visible.filter { !$0.isLive }.map(\.box)

        overlayModel.liveBox = live?.box
        overlayModel.historyBoxes = history
        overlayModel.isFadingOut = pipeline.shouldFadeLiveBox(now: now)
    }

    /// Toggle the history stack (bound to holding `⌥`).
    func setHistoryVisible(_ visible: Bool) {
        guard overlayModel.isShowingHistory != visible else { return }
        overlayModel.isShowingHistory = visible
        if visible {
            // Show the boxes the user has not seen yet.
            let boxes = pipeline.historyBoxes
            overlayModel.historyBoxes = boxes
        }
    }

    /// Filter the history stack by a search query.
    func search(_ query: String) -> [CaptionBox] {
        let results = pipeline.search(query)
        overlayModel.searchResults = Set(results.map(\.id))
        overlayModel.isShowingHistory = true
        overlayModel.historyBoxes = results
        return results
    }

    /// Close the history stack.
    func dismissHistory() {
        overlayModel.isShowingHistory = false
        overlayModel.searchResults = []
        overlayModel.historyBoxes = []
    }

    /// Present the search field for filtering the history stack.
    func presentSearch() {
        let alert = NSAlert()
        alert.messageText = "搜索历史字幕"
        alert.informativeText = "输入关键词，按回车筛选，按 Esc 关闭。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "关键词"
        alert.accessoryView = field
        alert.addButton(withTitle: "搜索")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            search(field.stringValue)
        } else {
            dismissHistory()
        }
        alert.window.initialFirstResponder = field
        alert.window.makeFirstResponder(field)
    }

    // MARK: - Overlay position and dragging

    /// Move the overlay back to the centre of the screen.
    func resetOverlayPosition() {
        overlay.resetPosition()
    }

    /// Begin dragging the overlay (bound to holding `⇧`).
    func beginOverlayDrag() {
        overlay.beginDragFromCurrentPointer()
    }

    /// Finish dragging the overlay.
    func endOverlayDrag() {
        overlay.endDrag()
    }

    // MARK: - Transcript

    /// All caption boxes seen so far, oldest first.
    var allBoxes: [CaptionBox] {
        var boxes = pipeline.historyBoxes
        if let live = pipeline.liveBox, !live.displayText.isEmpty {
            boxes.append(live)
        }
        return boxes
    }

    /// Save the transcript to a file.
    func saveTranscript(to url: URL) throws {
        try TranscriptExporter.write(boxes: allBoxes, to: url)
    }
}
