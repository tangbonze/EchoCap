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

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settings = AppSettings.shared
        let model = SettingsViewModel(settings: settings) { [weak self] in
            Task { await self?.controller?.reconfigure() }
        }
        let content = SettingsView(model: model, settings: settings)

        let hosting = NSHostingController(rootView: content)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "EchoCap 设置"
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        newWindow.setContentSize(NSSize(width: 640, height: 580))
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
    let settings: AppSettings

    var body: some View {
        TabView(selection: $model.selectedTab) {
            appearanceTab
                .tabItem { Label("外观", systemImage: "textformat") }
                .tag(SettingsTab.appearance)
            behaviourTab
                .tabItem { Label("行为", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.behaviour)
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(20)
        .frame(width: 640, height: 580)
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        Form {
            Section("字幕") {
                LabeledContent("文字大小") {
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

                LabeledContent("原文行数") {
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

                LabeledContent("译文行数") {
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

                LabeledContent("底板不透明度") {
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

                Picker("对齐", selection: Binding(
                    get: { settings.alignment },
                    set: { settings.alignment = $0 }
                )) {
                    ForEach(CaptionAlignment.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Picker("显示节奏", selection: Binding(
                    get: { settings.timing },
                    set: { settings.timing = $0 }
                )) {
                    ForEach(CaptionTiming.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            }

            Section("历史字幕") {
                LabeledContent("回溯数量") {
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

                LabeledContent("堆叠间距") {
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
        .formStyle(.grouped)
    }

    // MARK: - Behaviour

    private var behaviourTab: some View {
        Form {
            Section("声音") {
                Picker("聆听对象", selection: Binding(
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

                Picker("识别语言", selection: Binding(
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
            }

            Section("翻译") {
                Picker("翻译为", selection: Binding(
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

                Toggle("同时显示两种语言", isOn: Binding(
                    get: { settings.showBothLanguages },
                    set: { settings.showBothLanguages = $0 }
                ))

                Picker("朗读译文", selection: Binding(
                    get: { settings.speakMode },
                    set: { settings.speakMode = $0 }
                )) {
                    ForEach(SpeakMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("模型") {
                Toggle("跳过非语音（音乐、噪声）", isOn: Binding(
                    get: { settings.skipNonSpeech },
                    set: { settings.skipNonSpeech = $0 }
                ))

                Toggle("换人说话时另起一块字幕", isOn: Binding(
                    get: { settings.newBoxOnSpeakerChange },
                    set: { settings.newBoxOnSpeakerChange = $0 }
                ))

                LabeledContent("无新文字后淡出") {
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

                Toggle("显示来源应用名称", isOn: Binding(
                    get: { settings.showSourceAppName },
                    set: { settings.showSourceAppName = $0 }
                ))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About

    private var aboutTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                privacyCard
                shortcutsCard
                footer
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        }
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

    // MARK: - Privacy card

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("隐私", icon: "lock.shield.fill")

            VStack(alignment: .leading, spacing: 12) {
                promiseRow(
                    "lock.shield",
                    "音频不出这台 Mac",
                    "语音识别与翻译都由系统在本机完成，没有一个字节离开设备。"
                )
                promiseRow(
                    "person.crop.circle.badge.xmark",
                    "没有账号，没有遥测",
                    "不注册、不登录、不上报任何使用数据。"
                )
                promiseRow(
                    "arrow.down.circle",
                    "不用下载模型",
                    "直接用 macOS 自带的语音与翻译框架，装好即用。"
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
                KeyHintRow(keys: "⌥⌘S", label: "暂停 / 继续字幕")
                KeyHintRow(keys: "⌥", label: "按住回溯，堆叠历史字幕")
                KeyHintRow(keys: "⌥F", label: "搜索历史字幕")
                KeyHintRow(keys: "⇧", label: "按住拖动浮层")
                KeyHintRow(keys: "⌥⌘L", label: "调整浮层位置与大小（可拖动、可拉伸）")
                KeyHintRow(keys: "⌘,", label: "打开设置")
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
