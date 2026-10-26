import AppKit
import SwiftUI
import Combine
import EchoCapCore

/// Holds the editable state of the settings panel.
///
/// The panel drives these values with sliders and pickers, and writes them
/// back to `AppSettings` as they change.
final class SettingsViewModel: ObservableObject {
    @Published var fontSize: Double = 28
    @Published var boxOpacity: Double = 0.55
    @Published var dissolveRadius: Double = 90
    @Published var dissolveExtent: Double = 60
    @Published var linesPerBox: Double = 3
    @Published var historySpacing: Double = 8
    @Published var historyDepth: Double = 20
    @Published var fadeDelay: Double = 4

    private let settings: AppSettings
    private let onChange: () -> Void

    init(settings: AppSettings, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange

        fontSize = settings.fontSize
        boxOpacity = settings.boxOpacity
        dissolveRadius = settings.pointerDissolveRadius
        dissolveExtent = settings.pointerDissolveExtent
        linesPerBox = Double(settings.linesPerBox)
        historySpacing = settings.historySpacing
        historyDepth = Double(min(settings.historyDepth, 100))
        fadeDelay = settings.fadeDelay
    }

    /// Push the current slider values into the persisted settings.
    func commitAppearance() {
        settings.fontSize = fontSize
        settings.boxOpacity = boxOpacity
        settings.pointerDissolveRadius = dissolveRadius
        settings.pointerDissolveExtent = dissolveExtent
        settings.linesPerBox = Int(linesPerBox)
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
        TabView {
            appearanceTab
                .tabItem { Label("外观", systemImage: "textformat") }
            behaviourTab
                .tabItem { Label("行为", systemImage: "slider.horizontal.3") }
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
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

                LabeledContent("每屏行数") {
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

            Section("指针") {
                LabeledContent("淡出半径") {
                    HStack {
                        Slider(value: $model.dissolveRadius, in: 0...240, step: 5) { editing in
                            if !editing { model.commitAppearance() }
                        }
                        .frame(width: 180)
                        Text("\(Int(model.dissolveRadius))")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .leading)
                    }
                }

                LabeledContent("淡出过渡") {
                    HStack {
                        Slider(value: $model.dissolveExtent, in: 0...200, step: 5) { editing in
                            if !editing { model.commitAppearance() }
                        }
                        .frame(width: 180)
                        Text("\(Int(model.dissolveExtent))")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .leading)
                    }
                }

                Toggle("指针下方淡出", isOn: Binding(
                    get: { settings.fadeAwayUnderPointer },
                    set: { settings.fadeAwayUnderPointer = $0 }
                ))

                Toggle("浮层不吃点击", isOn: Binding(
                    get: { settings.clickThrough },
                    set: { settings.clickThrough = $0 }
                ))
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
        VStack(alignment: .leading, spacing: 14) {
            Text("EchoCap")
                .font(.system(size: 26, weight: .bold))
            Text("Mac 上播放什么，就配上实时字幕。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Label("音频不出这台 Mac", systemImage: "lock.shield")
                Label("没有账号，没有遥测，不联网", systemImage: "person.crop.circle.badge.xmark")
                Label("语音识别与翻译均由系统在本机完成", systemImage: "cpu")
            }
            .font(.system(size: 13))

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("快捷键")
                    .font(.headline)
                KeyHintRow(keys: "⌥⌘S", label: "暂停 / 继续字幕")
                KeyHintRow(keys: "⌥", label: "按住回溯并堆叠历史字幕")
                KeyHintRow(keys: "⌥F", label: "搜索历史字幕")
                KeyHintRow(keys: "⇧", label: "按住拖动浮层")
                KeyHintRow(keys: "⌘,", label: "打开设置")
                KeyHintRow(keys: "Esc", label: "关闭历史堆叠")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row in the shortcut list.
struct KeyHintRow: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 60, alignment: .leading)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
