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

    /// Watches for a capture that runs but never delivers sound.
    private var silenceWatchdog: Task<Void, Never>?

    /// The ◊ start/stop shortcut, re-registered whenever the user changes it.
    private var hotKey: GlobalHotKey?

    /// Told when the capture state changes, so the menu bar can follow.
    var onStateChanged: (() -> Void)?

    /// True while the saved geometry is being applied at launch, so the
    /// half-applied frame is not written back over the saved values.
    private var isRestoringGeometry = false

    /// When the current recording session began.
    private var sessionStartedAt = Date()

    /// True once this session has been offered up for saving.
    private var hasPromptedSession = false

    /// Loudest sample seen since the last report, 0…32767.
    private var peakLevel: Int = 0

    /// Loudest sample seen since capture started.
    private var peakSinceStart: Int = 0

    /// Samples still to be thrown away at the start of a capture.
    ///
    /// Opening a system-audio tap makes a click, and the recogniser turns that
    /// click into stray quotes and letters — the junk that used to sit at the
    /// top of the first caption of every session. The audio right after the tap
    /// opens is discarded instead of fed.
    private var samplesToDiscard = 0

    /// Samples left in the fade-in that follows the discard window.
    ///
    /// Jumping straight from nothing to full-scale audio is itself a click, and
    /// the recogniser hears that click. Ramping the first few milliseconds keeps
    /// the onset smooth.
    private var fadeInRemaining = 0
    private var fadeInTotal = 0

    private let discardLock = NSLock()
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

        overlay.onGeometryChanged = { [weak self] in
            guard let self, !self.isRestoringGeometry else { return }
            let frame = self.overlay.frame
            self.settings.overlayOrigin = "\(frame.origin.x),\(frame.origin.y)"
            self.settings.overlaySize = "\(frame.width),\(frame.height)"
            // Pagination has to measure against the width the user chose.
            self.pipeline.measurementWidth = self.textWidth(for: frame.size)
            self.refreshDisplay()
        }
    }

    // MARK: - Setup

    /// Prepare the UI. Called once at launch.
    func bootstrap() {
        overlay.orderFrontRegardless()

        // Read both saved values before touching the frame: applying the size
        // fires the geometry callback, which would otherwise overwrite the
        // saved origin with the placeholder (0,0) before it is read.
        isRestoringGeometry = true
        defer { isRestoringGeometry = false }

        // A size the user chose last time, if it still fits the screen.
        if let saved = settings.overlaySize {
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2, parts[0] >= 200, parts[1] >= 80 {
                overlay.restoreSize(NSSize(width: parts[0], height: parts[1]))
            }
        }

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

        // Give the window a definite size and paint the first frame, so the
        // overlay is composited even before the first caption arrives.
        overlay.setContentSize(overlay.frame.size)
        pipeline.measurementWidth = textWidth(for: overlay.frame.size)
        overlay.contentView?.needsLayout = true
        overlay.displayIfNeeded()

        // Test hook: place the overlay at an exact frame, e.g.
        // `--overlay-frame 200,500,800,220`.
        if let index = CommandLine.arguments.firstIndex(of: "--overlay-frame"),
           index + 1 < CommandLine.arguments.count {
            let parts = CommandLine.arguments[index + 1]
                .split(separator: ",")
                .compactMap { Double($0) }
            if parts.count == 4 {
                overlay.setFrame(
                    NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]),
                    display: true
                )
            }
        }

        // Test hook: show the end-of-recording prompt immediately.
        if CommandLine.arguments.contains("--test-prompt") {
            log("--test-prompt 开始")
            let now = Date()
            let box = CaptionBox(
                committedText: "This is a test caption used to exercise the save prompt.",
                translation: "这是一条用于测试保存提示的字幕。",
                sourceAppName: "Test"
            )
            // Pretend the user had been peeking at the history stack, so the
            // prompt's own "hide history" behaviour is what gets tested.
            // Two boxes: one history, one live — the "two parts" the user saw.
            let historyBox = CaptionBox(
                committedText: "I' Okay, so Google is dropping a brand new category of operating system.",
                translation: "",
                sourceAppName: "Test",
                createdAt: now.addingTimeInterval(-40),
                lastTextAt: now.addingTimeInterval(-30)
            )
            overlayModel.historyBoxes = [historyBox]
            overlayModel.liveBox = box
            overlayModel.isShowingHistory = true
            setHistoryVisible(false)
            SessionSavePrompt.present(
                boxes: [box],
                startedAt: now.addingTimeInterval(-125),
                summaryEngine: settings.summaryEngine,
                cloud: cloudConfig(model: settings.cloudSummaryModel),
            )
            return
        }

        reloadHotKey()

        if CommandLine.arguments.contains("--edit-layout") {
            setLayoutEditing(true)
        }

        startDisplayTimer()
    }

    /// Width caption text has to fit into for a given window size.
    private func textWidth(for size: NSSize) -> CGFloat {
        max(120, size.width - 24 * 2 - 16 * 2)
    }

    // MARK: - Layout editing

    /// Turn mouse interaction on so the overlay can be moved and resized.
    var isEditingLayout: Bool { overlay.isEditingLayout }

    func toggleLayoutEditing() {
        setLayoutEditing(!overlay.isEditingLayout)
    }

    func setLayoutEditing(_ editing: Bool) {
        overlay.setLayoutEditing(editing)
        overlayModel.isEditingLayout = editing
        statusText = editing
            ? "调整布局中：拖动移动，拖边角改大小"
            : "正在聆听"
        log(editing ? "进入布局调整（可拖动、可拉伸）" : "退出布局调整")
    }


    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshDisplay()
        }
        RunLoop.main.add(displayTimer!, forMode: .common)
    }

    // MARK: - Start / Stop

    /// Begin capturing and captioning.
    func start() async {
        guard !isRunning else { return }

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
                    guard let self else { return }

                    // Drop the click that opening the tap produces, then fade
                    // in so the first real sample is not a click either.
                    var output: [Int16] = []
                    output.reserveCapacity(samples.count)
                    self.discardLock.lock()
                    for sample in samples {
                        if self.samplesToDiscard > 0 {
                            self.samplesToDiscard -= 1
                            continue
                        }
                        if self.fadeInRemaining > 0 {
                            let done = Double(self.fadeInTotal - self.fadeInRemaining + 1)
                            let gain = done / Double(max(1, self.fadeInTotal))
                            output.append(Int16(clamping: Int(Double(sample) * gain)))
                            self.fadeInRemaining -= 1
                        } else {
                            output.append(sample)
                        }
                    }
                    self.discardLock.unlock()
                    guard !output.isEmpty else { return }

                    // Feed inline: the recogniser's input stream is
                    // thread-safe, and hopping through a task per chunk would
                    // let samples arrive out of order and garble the audio.
                    self.speech.feed(samples: output)
                    let count = samples.count
                    var peak = 0
                    for value in samples { peak = max(peak, abs(Int(value))) }
                    if peak > self.peakLevel { self.peakLevel = peak }
                    if peak > self.peakSinceStart { self.peakSinceStart = peak }
                    Task { @MainActor [weak self] in
                        self?.receivedSampleCount += count
                    }
                }
                systemCapture.onFailure = { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.log("采集失败: \(message)")
                    }
                }
                // Creating the tap blocks while macOS shows the Screen & System
                // Audio Recording prompt, and the user can take their time.
                //
                // Nothing is put on screen while that happens: a box that
                // appears and vanishes again is worse than a moment of silence,
                // and a failed start shows its own error.
                try await systemCapture.start(timeout: 90)
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
            // No automatic restart: if the user wants another go they press
            // ⌥⌘S, which is also what tells them something went wrong.
            return
        }

        log("采集已启动: \(source.displayName)")
        overlayModel.banner = nil
        isRunning = true
        receivedSampleCount = 0
        peakSinceStart = 0
        sessionStartedAt = Date()
        hasPromptedSession = false
        armStartupDiscard(sampleRate: speech.inputFormat?.sampleRate ?? 16_000)
        statusText = "正在聆听"
        lastError = nil
        startSilenceWatchdog(source: source)
        onStateChanged?()
    }

    /// Complain if the capture runs but no sound ever arrives.
    ///
    /// The usual cause is missing Screen & System Audio Recording permission:
    /// macOS hands back a tap that starts happily and then delivers **silence**,
    /// with no error anywhere. Silence is indistinguishable from "nothing is
    /// playing" from the app's point of view, so this waits long enough to be
    /// reasonably sure before saying anything.
    private func startSilenceWatchdog(source: AudioSource) {
        silenceWatchdog?.cancel()
        silenceWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.isRunning else { return }
            guard self.overlayModel.liveBox == nil else { return }

            let silent = self.peakSinceStart < 80
            let noSamples = self.receivedSampleCount == 0
            guard silent || noSamples else { return }

            self.overlayModel.banner = OverlayBanner(
                kind: .warning,
                title: "没有收到声音",
                detail: "如果是 EchoCap 更新过，请到「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」"
                    + "重新允许 EchoCap，再重开它。"
            )
            self.log(
                "6 秒内没有可用音频（采样 \(self.receivedSampleCount)，峰值 \(self.peakSinceStart)），"
                + "多半是缺少系统音频录制权限"
            )
        }
    }

    /// Stop capturing. The overlay keeps its last caption until it fades.
    ///
    /// - Parameter askToSave: ask whether to keep this recording once capture
    ///   has stopped. Off for restarts (source change, reconfigure) and for
    ///   quitting, which asks in its own way.
    func stop(askToSave: Bool = true) {
        guard isRunning else { return }
        isRunning = false
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        statusText = "已暂停"
        overlayModel.banner = nil
        onStateChanged?()
        systemCapture.stop()
        microphoneCapture.stop()
        speech.stop()

        if askToSave {
            promptSessionEnd()
        }
    }

    /// The shortcut as the user should read it.
    var hotKeyLabel: String { settings.keyboardShortcut.displayString }

    /// Throw away the first ~350 ms of a new capture.
    ///
    /// Kept out of the async `start()` so the lock stays in synchronous code.
    private func armStartupDiscard(sampleRate: Double) {
        discardLock.lock()
        samplesToDiscard = Int(sampleRate * 0.35)
        fadeInTotal = Int(sampleRate * 0.06)
        fadeInRemaining = fadeInTotal
        discardLock.unlock()
    }

    /// Register the user's start/stop shortcut.
    ///
    /// Dropping the old instance first unregisters it, so changing the shortcut
    /// never leaves two live hot keys behind.
    @discardableResult
    func reloadHotKey() -> Bool {
        hotKey = nil
        let shortcut = settings.keyboardShortcut
        let registered = GlobalHotKey(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.carbonModifiers
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.log("快捷键触发")
                await self?.toggle()
            }
        }
        hotKey = registered
        if registered.isRegistered {
            log("快捷键已注册：\(shortcut.displayString)")
        } else {
            log("快捷键注册失败（可能已被其他程序占用）：\(shortcut.displayString)")
        }
        return registered.isRegistered
    }

    /// Nothing is running: tell the user how to begin.
    ///
    /// Called at launch instead of starting the capture, so the app never
    /// begins listening on its own.
    func enterIdleState() {
        isRunning = false
        statusText = "未开始"
        // No on-screen hint: a caption overlay that sits there saying "press
        // the shortcut" is just clutter between sessions.
        overlayModel.banner = nil
        onStateChanged?()
    }

    /// Toggle between running and paused.
    func toggle() async {
        if isRunning { stop() } else { await start() }
    }



    /// Switch the audio source, restarting capture.
    func switchSource(_ source: AudioSource) async {
        guard settings.source != source else { return }
        settings.source = source
        let wasRunning = isRunning
        stop(askToSave: false)
        if wasRunning { await start() }
    }

    /// Restart recognition with a new language or translation target.
    func reconfigure() async {
        let wasRunning = isRunning
        stop(askToSave: false)
        assembler.reset()
        pipeline.reset()
        if wasRunning { await start() }
    }

    // MARK: - Model engines

    /// The cloud endpoint as configured, with the given model name filled in.
    ///
    /// The key is only read out of the Keychain when a cloud engine is
    /// actually in use: reading it makes macOS ask the user for permission, and
    /// with both engines on "local" there is nothing to ask about.
    func cloudConfig(model: String) -> CloudLLMConfig {
        let usesCloud = settings.translationEngine == .cloud || settings.summaryEngine == .cloud
        return CloudLLMConfig(
            baseURL: settings.cloudBaseURL,
            apiKey: usesCloud ? CloudCredentialStore.apiKey() : "",
            model: model
        )
    }

    /// Whether the chosen engines are ready, for the menu to show.
    var summaryAvailability: SummaryService.Availability {
        SummaryService.availability(
            engine: settings.summaryEngine,
            cloud: cloudConfig(model: settings.cloudSummaryModel)
        )
    }

    /// Re-configure translation after the engine or endpoint changed.
    func translationSettingsChanged() async {
        await configureTranslation(
            recognitionLocale: activeRecognitionLanguage,
            target: activeTranslationTarget
        )
        // A different endpoint may answer at a different speed; give the cloud
        // path a little more room before the next request.
        translationThrottle = settings.translationEngine == .cloud ? 0.8 : 0.3
    }

    // MARK: - Translation

    private func configureTranslation(recognitionLocale: Locale?, target targetID: String?) async {
        guard let targetID,
              let target = LanguageCatalog.language(for: targetID) else {
            await translation.reset()
            return
        }

        // The recogniser's own locale is often a macrolanguage placeholder
        // ("mul_IN" for the multilingual model) which no translator accepts —
        // handing it over makes prepareTranslation hang forever. Resolve to a
        // real language first.
        let source = TranslationSourceLocale.resolve(
            recognised: recognitionLocale?.language,
            detected: detectedSourceLanguage
        )
        if source.languageCode?.identifier == "en",
           recognitionLocale?.language.languageCode?.identifier == "mul" {
            log("识别是多语种模型，翻译源语言退回英文")
        }

        // Never let a stuck model block the whole session.
        let service = translation
        let engine = settings.translationEngine
        let cloud = cloudConfig(model: settings.cloudTranslationModel)
        let targetLanguage = target.language
        let targetName = target.englishName
        let ok = await Self.withTimeout(seconds: 12, fallback: false) {
            await service.configure(
                source: source,
                target: targetLanguage,
                engine: engine,
                cloud: cloud,
                targetName: targetName
            )
        }
        if !ok {
            log("翻译引擎不可用或超时：\(settings.translationEngine.displayName)")
        }
    }
    /// Run an operation, giving up after `seconds`.
    ///
    /// Loading a translation model can block indefinitely when it dislikes the
    /// language pair or starts a download the user never sees. The caption
    /// pipeline must not stall behind that.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return fallback
            }
            let first = await group.next() ?? fallback
            group.cancelAll()
            return first
        }
    }

    // MARK: - Recognition handling

    private func handleRecognition(text: String, isFinal: Bool, rangeStart: Double) {
        // Turn the recogniser's cumulative text into a segment update.
        if diagnosticLog {
            log("RAW final=\(isFinal) range=\(String(format: "%.4f", rangeStart)) len=\(text.count) tail=\(text.suffix(28))")
        }
        // Quote-and-letter soup from a click is not speech.
        if CaptionTextSanitizer.isNoise(text) {
            log("丢弃疑似噪声：\(text)")
            return
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

        // The "listening…" placeholder has done its job once words arrive.
        if overlayModel.banner != nil {
            overlayModel.banner = nil
        }

        if diagnosticLog {
            let kind = update.isFinal ? "定稿" : "实时"
            let shown = pipeline.liveBox?.displayText ?? update.text
            log("\(kind): \(shown)")
        }

        // Translate what is on screen, not only finished sentences. Waiting for
        // the segment to close made the translation trail the captions by
        // seconds — by the time it appeared, the reader had moved on.
        if activeTranslationTarget != nil {
            let onScreen = pipeline.liveBox?.displayText ?? update.text
            requestTranslation(for: onScreen, isFinal: update.isFinal)
        }

        refreshDisplay()
    }

    // MARK: - Translation

    /// Whether a live translation request is already running.
    private var translationInFlight = false
    /// When the last live request was sent, used to throttle.
    private var lastTranslationRequest = Date.distantPast
    /// The source text that was last sent, so identical text is not re-sent.
    private var lastTranslatedSource = ""
    /// Shortest gap between live translation requests. A cloud round trip is
    /// slower, so it gets more room.
    private var translationThrottle: TimeInterval = 0.3

    /// Translate `text`, cheaply enough to run while the speaker is talking.
    ///
    /// Only one request runs at a time and requests are throttled, so a fast
    /// talker cannot queue up work faster than the session can answer.
    private func requestTranslation(for text: String, isFinal: Bool) {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }

        let boxID = pipeline.liveBox?.id
        if !isFinal {
            guard !translationInFlight else { return }
            guard source != lastTranslatedSource else { return }
            guard Date().timeIntervalSince(lastTranslationRequest) >= translationThrottle else {
                return
            }
        }

        translationInFlight = true
        lastTranslationRequest = Date()
        lastTranslatedSource = source

        let startedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            let translated = await self.translation.translate(source)
            self.translationInFlight = false
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard let translated else {
                let reason = await self.translation.lastError ?? "未知原因"
                self.log("译文失败：\(reason)")
                return
            }
            // A live result belongs to the box that was on screen when the
            // request went out; by now it may already have scrolled away.
            if !isFinal, let boxID, self.pipeline.liveBox?.id != boxID {
                return
            }
            self.pipeline.setTranslation(translated, isFinal: isFinal)
            self.log("译文(\(isFinal ? "定稿" : "实时"), \(elapsed)ms): \(translated)")
            self.refreshDisplay()
        }
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
            log(
                "浮层 frame=\(overlay.frame) visible=\(overlay.isVisible)"
                + " alpha=\(overlay.alphaValue) live=\(overlayModel.liveBox?.displayText ?? "nil")"
                + " banner=\(overlayModel.banner == nil ? "nil" : "有")"
            )
            log(
                "内容 content=\(overlay.contentView.map { "\($0.frame)" } ?? "nil")"
                + " container=\(overlayModel.containerSize)"
                + " fading=\(overlayModel.isFadingOut)"
                + " history=\(overlayModel.historyBoxes.count)"
                + " size=\(Int(overlay.frame.width))x\(Int(overlay.frame.height))"
                + " editing=\(overlay.isEditingLayout) clickable=\(!overlay.ignoresMouseEvents)"
                + " peak=\(peakLevel)"
            )
            peakLevel = 0
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

        // Nudge the hosting view. Without an explicit layout+display pass the
        // first caption can stay invisible until something else happens to
        // invalidate the window.
        overlay.contentView?.needsLayout = true
        overlay.contentView?.needsDisplay = true
        overlay.displayIfNeeded()
    }

    /// Toggle the history stack (bound to holding `⌥`).
    func setHistoryVisible(_ visible: Bool) {
        guard overlayModel.isShowingHistory != visible else { return }
        log("历史显示 → \(visible)")
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

    /// Whether this session has captions the user has not been asked about.
    var hasUnsavedTranscript: Bool {
        !hasPromptedSession && !allBoxes.isEmpty
    }

    /// Ask whether to keep the recording that just ended.
    ///
    /// - Parameter onFinish: called once the user is done, saved or not.
    func promptSessionEnd(onFinish: (() -> Void)? = nil) {
        guard !hasPromptedSession else {
            onFinish?()
            return
        }
        let boxes = allBoxes
        guard !boxes.isEmpty else {
            onFinish?()
            return
        }
        // The prompt is about saving, not browsing: drop the history stack so
        // it does not sit behind the dialog looking like a second caption.
        setHistoryVisible(false)
        hasPromptedSession = true
        // Drop the history stack before the dialog appears: it is about
        // saving, not browsing, and a stacked history behind the dialog looks
        // like the caption split in two.
        setHistoryVisible(false)
        SessionSavePrompt.present(
            boxes: boxes,
            startedAt: sessionStartedAt,
            summaryEngine: settings.summaryEngine,
            cloud: cloudConfig(model: settings.cloudSummaryModel),
            onHideHistory: { [weak self] in self?.setHistoryVisible(false) },
            onFinish: onFinish
        )
    }

    /// Quit, offering to keep the recording on the way out.
    ///
    /// Asking from the menu works; asking from `applicationShouldTerminate`
    /// does not, because AppKit is already tearing the app down by then.
    func requestQuit() {
        promptSessionEnd {
            NSApp.terminate(nil)
        }
    }

    /// Save the transcript to a file.
    func saveTranscript(to url: URL) throws {
        try TranscriptExporter.write(boxes: allBoxes, to: url)
    }
}
