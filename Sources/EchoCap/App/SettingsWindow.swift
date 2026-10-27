import AppKit
import SwiftUI
import Combine
import EchoCapCore

/// Which tab of the settings panel is showing.
enum SettingsTab: String, Hashable, CaseIterable {
    case appearance
    case behaviour
    case about

    var title: String {
        switch self {
        case .appearance: return "外观"
        case .behaviour: return "行为"
        case .about: return "关于"
        }
    }
}

/// Holds the editable state of the settings panel.
///
/// The panel drives these values with sliders and pickers, and writes them
/// back to `AppSettings` as they change.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var fontSize: Double = 28
    @Published var boxOpacity: Double = 0.55
    @Published var linesPerBox: Double = 2
    @Published var translationLines: Double = 2
    @Published var historySpacing: Double = 8
    @Published var historyDepth: Double = 20
    @Published var fadeDelay: Double = 4
    /// The tab on screen. Lives here rather than in `@State` so the app target
    /// does not need the SwiftUI macro plugin.
    @Published var selectedTab: SettingsTab = .appearance

    // Cloud endpoint
    @Published var cloudBaseURL: String = ""
    @Published var cloudTranslationModel: String = ""
    @Published var cloudSummaryModel: String = ""
    @Published var cloudAPIKey: String = ""
    @Published var cloudStatus: String = ""

    /// Models the endpoint reported, for the pickers.
    @Published var detectedModels: [String] = []
    @Published var isDetectingModels = false

    /// Called when the translation engine changed, so the app can swap without
    /// restarting the whole recogniser.
    var onEngineChanged: (() -> Void)?

    /// Called after the shortcut changed, so the app can re-register it.
    var onShortcutChanged: (() -> Void)?

    /// Result of the last shortcut registration attempt.
    @Published var shortcutStatus: String = ""

    func shortcutChanged() {
        onShortcutChanged?()
    }

    private let settings: AppSettings
    private let onChange: () -> Void

    init(settings: AppSettings, onChange: @escaping () -> Void, initialTab: SettingsTab = .appearance) {
        self.settings = settings
        self.onChange = onChange
        selectedTab = initialTab

        fontSize = settings.fontSize
        boxOpacity = settings.boxOpacity
        linesPerBox = Double(settings.linesPerBox)
        translationLines = Double(settings.translationLines)
        historySpacing = settings.historySpacing
        historyDepth = Double(min(settings.historyDepth, 100))
        fadeDelay = settings.fadeDelay
        cloudBaseURL = settings.cloudBaseURL
        cloudTranslationModel = settings.cloudTranslationModel
        cloudSummaryModel = settings.cloudSummaryModel
        // Not read here on purpose: touching the Keychain makes macOS ask for
        // permission, and the field can stay empty to mean "keep the saved one".
        cloudAPIKey = ""
    }

    /// Persist the cloud endpoint and the key (the key goes to the Keychain).
    func commitCloud() {
        settings.cloudBaseURL = cloudBaseURL.trimmingCharacters(in: .whitespaces)
        settings.cloudTranslationModel = cloudTranslationModel.trimmingCharacters(in: .whitespaces)
        settings.cloudSummaryModel = cloudSummaryModel.trimmingCharacters(in: .whitespaces)
        let typedKey = cloudAPIKey.trimmingCharacters(in: .whitespaces)
        if !typedKey.isEmpty {
            CloudCredentialStore.setAPIKey(typedKey)
            cloudAPIKey = ""
            cloudStatus = "API Key 已保存到钥匙串"
        }
        onEngineChanged?()
    }

    /// Swap the translation engine without restarting capture.
    func engineChanged() {
        commitCloud()
        onEngineChanged?()
    }

    /// Look the model list up after the endpoint or key changes.
    ///
    /// Debounced: typing an address fires this on every keystroke otherwise,
    /// and each attempt is a network round trip.
    func scheduleModelDetection() {
        detectionTask?.cancel()
        guard !cloudBaseURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            detectedModels = []
            return
        }
        detectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self else { return }
            self.detectModels(announceFailure: false, useStoredKey: false)
        }
    }

    private var detectionTask: Task<Void, Never>?
    private let cloudClient = CloudLLMClient(timeout: 15)

    /// Ask the endpoint which models it offers, and fill the pickers.
    ///
    /// - Parameter useStoredKey: read the Keychain for the API key. Off for the
    ///   automatic attempt so opening the panel never triggers a Keychain
    ///   permission prompt; on when the user asks for the list explicitly.
    func detectModels(announceFailure: Bool = true, useStoredKey: Bool = true) {
        commitCloud()
        let key = useStoredKey
            ? CloudCredentialStore.apiKey()
            : cloudAPIKey.trimmingCharacters(in: .whitespaces)
        let config = CloudLLMConfig(
            baseURL: settings.cloudBaseURL,
            apiKey: key,
            model: "-"
        )
        guard !config.baseURL.isEmpty else {
            cloudStatus = "先填接口地址"
            return
        }

        isDetectingModels = true
        Task {
            do {
                let names = try await cloudClient.models(config: config)
                detectedModels = names
                cloudStatus = "发现 \(names.count) 个模型，从下拉里选"
                // Give each slot a starting value so nothing is left blank.
                if settings.cloudTranslationModel.isEmpty, let first = names.first {
                    cloudTranslationModel = first
                    settings.cloudTranslationModel = first
                }
                if settings.cloudSummaryModel.isEmpty, let first = names.first {
                    cloudSummaryModel = first
                    settings.cloudSummaryModel = first
                }
            } catch {
                detectedModels = []
                if announceFailure {
                    cloudStatus = error.localizedDescription
                } else {
                    cloudStatus = "没能取到模型列表（\(error.localizedDescription)），可以直接手填"
                }
            }
            isDetectingModels = false
        }
    }

    /// Try the endpoint with a trivial request.
    func testCloudConnection() {
        commitCloud()
        cloudStatus = "正在连接…"
        detectModels(announceFailure: false, useStoredKey: true)
        let config = CloudLLMConfig(
            baseURL: settings.cloudBaseURL,
            apiKey: CloudCredentialStore.apiKey(),
            model: !settings.cloudTranslationModel.isEmpty
                ? settings.cloudTranslationModel
                : settings.cloudSummaryModel
        )
        Task {
            do {
                let reply = try await CloudLLMClient(timeout: 15).complete(
                    system: "Reply with exactly: ok",
                    user: "ping",
                    config: config
                )
                cloudStatus = "连接成功：\(reply.prefix(60))"
            } catch {
                cloudStatus = error.localizedDescription
            }
        }
    }

    /// Push the current slider values into the persisted settings.
    func commitAppearance() {
        settings.fontSize = fontSize
        settings.boxOpacity = boxOpacity
        settings.linesPerBox = Int(linesPerBox)
        settings.translationLines = Int(translationLines)
        settings.historySpacing = historySpacing
        settings.historyDepth = Int(historyDepth)
        settings.fadeDelay = fadeDelay
    }

    /// Notify the app that something affecting the engine changed.
    func requestReconfigure() {
        commitAppearance()
        onChange()
    }
}

/// Hosts the settings window.
@available(macOS 26.0, *)
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var controller: AppController?

    func configure(with controller: AppController) {
        self.controller = controller
    }

    func show(initialTab: SettingsTab = .appearance) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settings = AppSettings.shared
        let model = SettingsViewModel(settings: settings, onChange: { [weak self] in
            Task { await self?.controller?.reconfigure() }
        }, initialTab: initialTab)
        model.onEngineChanged = { [weak self] in
            Task { await self?.controller?.translationSettingsChanged() }
        }
        model.onShortcutChanged = { [weak self] in
            guard let controller = self?.controller else { return }
            let ok = controller.reloadHotKey()
            model.shortcutStatus = ok ? "已生效" : "注册失败：可能被别的程序占用，换一个试试"
        }
        // Fill the model pickers straight away when an endpoint is configured.
        model.scheduleModelDetection()
        let content = SettingsView(model: model, settings: settings)

        let hosting = NSHostingController(rootView: content)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "EchoCap 设置"
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        newWindow.setContentSize(NSSize(width: 640, height: 700))
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The settings panel.
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    /// Observed, not merely held: the panel binds straight to it, and without
    /// this the controls keep showing the old value after a change.
    @ObservedObject var settings: AppSettings

    /// Panel height. The preview renders taller so every section shows.
    var frameHeight: CGFloat = 700

    var body: some View {
        VStack(spacing: 0) {
            CapsuleTabSwitcher(selection: $model.selectedTab)
                .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    switch model.selectedTab {
                    case .appearance: appearanceTab
                    case .behaviour: behaviourTab
                    case .about: aboutTab
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 24)
                .padding(.bottom, 34)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(width: 640, height: frameHeight)
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsGroup(title: "字幕") {
                SettingsRow(label: "文字大小", showDivider: true) {
                    HStack {
                        Slider(value: $model.fontSize, in: 14...56, step: 1) { editing in
                            if !editing { model.commitAppearance() }
                        }
                        .frame(width: 180)
                        Text("\(Int(model.fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .leading)
                    }
                }

                SettingsRow(label: "原文行数", showDivider: true) {
                    HStack {
                        Slider(value: $model.linesPerBox, in: 1...6, step: 1) { editing in
                            if !editing { model.commitAppearance() }
                        }
                        .frame(width: 180)
                        Text("\(Int(model.linesPerBox))")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .leading)
                    }
                }

                SettingsRow(label: "译文行数", showDivider: true) {
                    HStack {
                        Slider(value: $model.translationLines, in: 1...4, step: 1) { editing in
                            if !editing { model.commitAppearance() }
                        }
                        .frame(width: 180)
                        Text("\(Int(model.translationLines))")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .leading)
                    }
                }

                SettingsRow(label: "底板不透明度", showDivider: true) {
                    HStack {
                        Slider(value: $model.boxOpacity, in: 0...1, step: 0.05) { editing in
                            if !editing { model.commitAppearance() }
                        }
                        .frame(width: 180)
                        Text("\(Int(model.boxOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .leading)
                    }
                }

                SettingsRow(label: "字母对齐方式", showDivider: true) {
                    Picker("", selection: Binding(
                        get: { settings.alignment },
                        set: { settings.alignment = $0 }
                    )) {
                        ForEach(CaptionAlignment.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingsRow(label: "显示节奏") {
                    Picker("", selection: Binding(
                        get: { settings.timing },
                        set: { settings.timing = $0 }
                    )) {
                        ForEach(CaptionTiming.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsGroup(title: "历史字幕") {
                SettingsRow(label: "回溯数量", showDivider: true) {
                    HStack {
                        Slider(value: $model.historyDepth, in: 1...100, step: 1) { editing in
                            if !editing { model.commitAppearance() }
                        }
                        .frame(width: 180)
                        Text("\(Int(model.historyDepth))")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .leading)
                    }
                }

                SettingsRow(label: "堆叠间距") {
                    HStack {
                        Slider(value: $model.historySpacing, in: 0...40, step: 1) { editing in
                            if !editing { model.commitAppearance() }
                        }
                        .frame(width: 180)
                        Text("\(Int(model.historySpacing))")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: - Behaviour

    private var behaviourTab: some View {
        VStack(alignment: .leading, spacing: 30) {
            SettingsGroup(title: "声音") {
                SettingsRow(label: "聆听对象", showDivider: true) {
                    Picker("", selection: Binding(
                        get: { settings.source },
                        set: { newValue in
                            settings.source = newValue
                            model.requestReconfigure()
                        }
                    )) {
                        ForEach(AudioSource.allCases, id: \.self) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingsRow(label: "识别语言") {
                    Picker("", selection: Binding(
                        get: { settings.recognitionLanguage ?? "" },
                        set: { newValue in
                            settings.recognitionLanguage = newValue.isEmpty ? nil : newValue
                            model.requestReconfigure()
                        }
                    )) {
                        Text("自动检测").tag("")
                        ForEach(LanguageCatalog.all) { language in
                            Text(language.displayName).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsGroup(
                title: "快捷键",
                footer: model.shortcutStatus.isEmpty
                    ? "点一下下面的方框，然后按下想用的组合键（至少含 ⌘、⌥ 或 ⌃），在任何 App 里都生效。"
                    : model.shortcutStatus
            ) {
                SettingsRow(label: "开始 / 暂停聆听") {
                    HStack(spacing: 8) {
                        ShortcutRecorderView(shortcut: Binding(
                            get: { settings.keyboardShortcut },
                            set: { newValue in
                                settings.keyboardShortcut = newValue
                                model.shortcutChanged()
                            }
                        ))
                        .frame(width: 170, height: 26)

                        Button("恢复默认") {
                            settings.keyboardShortcut = .default
                            model.shortcutChanged()
                        }
                        .fixedSize()
                    }
                }
            }
            SettingsGroup(title: "翻译") {
                SettingsRow(label: "翻译为", showDivider: true) {
                    Picker("", selection: Binding(
                        get: { settings.translationTarget ?? "" },
                        set: { newValue in
                            settings.translationTarget = newValue.isEmpty ? nil : newValue
                            model.requestReconfigure()
                        }
                    )) {
                        Text("关闭").tag("")
                        ForEach(LanguageCatalog.all) { language in
                            Text(language.displayName).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingsRow(label: "翻译引擎", showDivider: true) {
                    Picker("", selection: Binding(
                        get: { settings.translationEngine },
                        set: { engine in
                            settings.translationEngine = engine
                            model.engineChanged()
                        }
                    )) {
                        ForEach(ModelEngine.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingsRow(label: "同时显示两种语言", showDivider: true) {
                    Toggle("", isOn: Binding(
                        get: { settings.showBothLanguages },
                        set: { settings.showBothLanguages = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                SettingsRow(label: "朗读译文") {
                    Picker("", selection: Binding(
                        get: { settings.speakMode },
                        set: { settings.speakMode = $0 }
                    )) {
                        ForEach(SpeakMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsGroup(
                title: "AI 摘要",
                footer: "录制结束时会问你要不要保存，选了「生成摘要」才用到这里挑的模型。语音识别始终在本机，不受这里影响。"
            ) {
                SettingsRow(label: "摘要引擎") {
                    Picker("", selection: Binding(
                        get: { settings.summaryEngine },
                        set: { settings.summaryEngine = $0 }
                    )) {
                        ForEach(ModelEngine.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsGroup(
                title: "云端 API",
                footer: "兼容 OpenAI 接口的服务都能用（OpenAI、DeepSeek、Moonshot、本地 Ollama 等）。API Key 存在系统钥匙串里，不写进偏好设置。"
            ) {
                SettingsRow(label: "接口地址", showDivider: true) {
                    TextField("", text: $model.cloudBaseURL, prompt: Text("https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                        .onSubmit { model.commitCloud() }
                        .onChange(of: model.cloudBaseURL) { _, _ in model.scheduleModelDetection() }
                }

                SettingsRow(label: "API Key", showDivider: true) {
                    SecureField("", text: $model.cloudAPIKey, prompt: Text("留空沿用已保存的"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                        .onSubmit { model.commitCloud() }
                        .onChange(of: model.cloudAPIKey) { _, _ in model.scheduleModelDetection() }
                }

                SettingsRow(label: "翻译模型", showDivider: true) {
                    modelPicker("翻译模型", selection: $model.cloudTranslationModel)
                }

                SettingsRow(label: "总结模型", showDivider: true) {
                    modelPicker("总结模型", selection: $model.cloudSummaryModel)
                }

                SettingsRow(label: "") {
                    HStack(spacing: 10) {
                        Button("保存配置") { model.commitCloud() }
                        Button("清除 Key") {
                            CloudCredentialStore.setAPIKey("")
                            model.cloudStatus = "已清除保存的 API Key"
                        }
                        Button {
                            model.detectModels()
                        } label: {
                            Text(model.isDetectingModels ? "正在获取…" : "获取模型列表")
                        }
                        .disabled(model.isDetectingModels)
                        Button("测试连接") { model.testCloudConnection() }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if !model.cloudStatus.isEmpty {
                    Text(model.cloudStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            SettingsGroup(title: "模型") {
                SettingsRow(label: "跳过非语音（音乐、噪声）", showDivider: true) {
                    Toggle("", isOn: Binding(
                        get: { settings.skipNonSpeech },
                        set: { settings.skipNonSpeech = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                SettingsRow(label: "换人说话时另起一块字幕", showDivider: true) {
                    Toggle("", isOn: Binding(
                        get: { settings.newBoxOnSpeakerChange },
                        set: { settings.newBoxOnSpeakerChange = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }

                SettingsRow(label: "无新文字后淡出", showDivider: true) {
                    HStack {
                        Slider(value: $model.fadeDelay, in: 1...12, step: 0.5) { editing in
                            if !editing { model.commitAppearance() }
                        }
                        .frame(width: 180)
                        Text("\(model.fadeDelay, specifier: "%.1f")s")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .leading)
                    }
                }

                SettingsRow(label: "显示来源应用名称") {
                    Toggle("", isOn: Binding(
                        get: { settings.showSourceAppName },
                        set: { settings.showSourceAppName = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - Behaviour

    
    // MARK: - About

    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                featureCard
                privacyCard
                shortcutsCard
                footer
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        }
        // Form 自带窗口底色；这一页是 ScrollView，需要显式给同样的背景，
        // 否则离屏渲染时是透明的（看起来像黑底）。
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(nsImage: Self.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)

            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    Text("EchoCap")
                        .font(.system(size: 26, weight: .bold))
                    Text(Self.version)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                }

                Text("Mac 上播放什么，就配上实时字幕")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Feature card

    private var featureCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("它能做什么", icon: "sparkles")

            VStack(alignment: .leading, spacing: 12) {
                promiseRow(
                    "waveform",
                    "实时字幕",
                    "Mac 播放的任何声音——视频、会议、播客——实时转成文字，延迟通常不到一秒。"
                )
                promiseRow(
                    "globe",
                    "实时翻译",
                    "把听到的内容翻成中文等语言，原文译文同屏显示；本机与云端两种引擎任选。"
                )
                promiseRow(
                    "text.badge.star",
                    "AI 摘要",
                    "录制结束后一键生成要点，用本机模型或你配置的云端 API。"
                )
                promiseRow(
                    "clock.arrow.circlepath",
                    "历史回溯与导出",
                    "按住 ⌥ 回看之前的字幕并支持全文搜索；结束时保存为 Markdown 或纯文本。"
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(cardBackground)
    }

    // MARK: - Privacy card

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("隐私", icon: "lock.shield.fill")

            VStack(alignment: .leading, spacing: 12) {
                promiseRow(
                    "lock.shield",
                    "本机模式下，音频不出这台 Mac",
                    "语音识别与翻译都由系统在本机完成，没有一个字节离开设备。只有手动选了云端引擎，才会把识别出的文字（不是音频）发给你自己配置的服务。"
                )
                promiseRow(
                    "person.crop.circle.badge.xmark",
                    "没有账号，没有遥测",
                    "不注册、不登录、不上报任何使用数据。"
                )
                promiseRow(
                    "internaldrive",
                    "模型自动就位",
                    "首次使用会自动下载系统语音识别模型，之后完全离线可用。"
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(cardBackground)
    }

    private func promiseRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Shortcuts card

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("快捷键", icon: "command")

            VStack(spacing: 7) {
                KeyHintRow(keys: settings.keyboardShortcut.displayString, label: "开始 / 暂停聆听（任何 App 里都可用）")
                KeyHintRow(keys: "⌥", label: "按住回溯，堆叠历史字幕")
                KeyHintRow(keys: "⌥F", label: "搜索历史字幕")
                KeyHintRow(keys: "⇧", label: "按住拖动浮层")
                KeyHintRow(keys: "⌥⌘L", label: "调整浮层位置与大小（可拖动、可拉伸）")
                KeyHintRow(keys: "Esc", label: "关闭历史堆叠")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(cardBackground)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 9) {
            Link(destination: URL(string: "https://github.com/tangbonze/EchoCap")!) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right.square")
                    Text("github.com/tangbonze/EchoCap")
                }
                .font(.system(size: 12))
            }

            Text("需要 macOS 26 或更高版本 · Apple silicon")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    /// A model slot: a dropdown when the endpoint told us what it offers, a
    /// free-text field when it did not.
    @ViewBuilder
    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        if model.detectedModels.isEmpty {
            TextField(title, text: selection, prompt: Text("填模型名，或点「获取模型列表」"))
                .onSubmit { model.commitCloud() }
        } else {
            Picker(title, selection: Binding(
                get: { selection.wrappedValue },
                set: { newValue in
                    selection.wrappedValue = newValue
                    model.commitCloud()
                }
            )) {
                if selection.wrappedValue.isEmpty {
                    Text("选择模型").tag("")
                }
                ForEach(model.detectedModels, id: \.self) { name in
                    Text(name).tag(name)
                }
                // Keep a hand-typed name selectable even if the list omits it.
                if !selection.wrappedValue.isEmpty,
                   !model.detectedModels.contains(selection.wrappedValue) {
                    Text("\(selection.wrappedValue)（手动填写）").tag(selection.wrappedValue)
                }
            }
        }
    }

    // MARK: - Shared pieces

    private func cardHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }

    /// The app icon: the bundled one when there is one, otherwise the
    /// system placeholder.
    static var appIcon: NSImage {
        if let url = Bundle.main.url(forResource: "EchoCap", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // When running outside a bundle (the preview tool), fall back to the
        // generated icon next to the executable or one directory above it.
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        for candidate in [
            executableDirectory.appendingPathComponent("EchoCap.icns"),
            executableDirectory.deletingLastPathComponent().appendingPathComponent("EchoCap.icns"),
        ] {
            if let image = NSImage(contentsOf: candidate) {
                return image
            }
        }
        return NSApp.applicationIconImage
    }

    /// The app version, read from the bundle.
    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "1.0.0"
    }
}

struct KeyHintRow: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 62, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }
}
