import Foundation
import Combine

/// Where the audio being captioned comes from.
public enum AudioSource: String, Codable, CaseIterable, Sendable {
    /// Everything the Mac is playing, from any app.
    case systemAudio
    /// The built-in or selected microphone.
    case microphone

    public var displayName: String {
        switch self {
        case .systemAudio: return "所有系统音频"
        case .microphone: return "麦克风"
        }
    }
}

/// How the overlay presents text as it arrives.
public enum CaptionTiming: String, Codable, CaseIterable, Sendable {
    /// Text appears immediately and dims only once it settles.
    case liveThenSettle
    /// Text always renders live, even while it is being revised.
    case alwaysLive

    public var displayName: String {
        switch self {
        case .liveThenSettle: return "先实时后落定"
        case .alwaysLive: return "始终实时"
        }
    }
}

/// Text alignment inside the overlay.
public enum CaptionAlignment: String, Codable, CaseIterable, Sendable {
    case start
    case center

    public var displayName: String {
        switch self {
        case .start: return "起始对齐"
        case .center: return "居中"
        }
    }
}

/// Voice used to read the translation aloud.
public enum SpeakMode: String, Codable, CaseIterable, Sendable {
    case off
    case always
    case followVoiceOver

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .always: return "始终朗读"
        case .followVoiceOver: return "跟随旁白"
        }
    }
}

/// Everything the user can tune. Persisted in `UserDefaults`.
public final class AppSettings: ObservableObject, @unchecked Sendable {
    /// Fired after any setting changes.
    ///
    /// The settings panel binds straight to this object, so without a
    /// notification SwiftUI keeps drawing the old value — the change takes
    /// effect but the control does not move until the panel is reopened.
    public let objectWillChange = ObservableObjectPublisher()

    /// Write a value and tell the UI about it.
    private func store<T>(_ value: T, _ key: String) {
        defaults.set(value, forKey: key)
        objectWillChange.send()
    }

    public static let shared = AppSettings()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Audio

    public var source: AudioSource {
        get { AudioSource(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .systemAudio }
        set { store(newValue.rawValue, Keys.source) }
    }

    /// Bundle identifiers excluded from system-audio capture.
    public var excludedBundleIDs: Set<String> {
        get {
            let raw = defaults.stringArray(forKey: Keys.excluded) ?? []
            return Set(raw)
        }
        set { store(Array(newValue).sorted(), Keys.excluded) }
    }

    /// Recogniser language; `nil` means auto-detect.
    public var recognitionLanguage: String? {
        get { defaults.string(forKey: Keys.recognitionLang) }
        set { store(newValue, Keys.recognitionLang) }
    }

    // MARK: - Translation

    /// Target language for translation; `nil` disables translation.
    public var translationTarget: String? {
        get { defaults.string(forKey: Keys.translationTarget) }
        set { store(newValue, Keys.translationTarget) }
    }

    public var showBothLanguages: Bool {
        get { defaults.object(forKey: Keys.showBoth) as? Bool ?? true }
        set { store(newValue, Keys.showBoth) }
    }

    public var speakMode: SpeakMode {
        get { SpeakMode(rawValue: defaults.string(forKey: Keys.speak) ?? "") ?? .off }
        set { store(newValue.rawValue, Keys.speak) }
    }

    /// Duck the original audio while the translation is being spoken.
    public var lowerOriginalWhileSpeaking: Bool {
        get { defaults.object(forKey: Keys.duck) as? Bool ?? true }
        set { store(newValue, Keys.duck) }
    }

    // MARK: - Appearance

    public var fontSize: Double {
        get { defaults.object(forKey: Keys.fontSize) as? Double ?? 28 }
        set { store(newValue, Keys.fontSize) }
    }

    public var alignment: CaptionAlignment {
        get { CaptionAlignment(rawValue: defaults.string(forKey: Keys.alignment) ?? "") ?? .start }
        set { store(newValue.rawValue, Keys.alignment) }
    }

    public var timing: CaptionTiming {
        get { CaptionTiming(rawValue: defaults.string(forKey: Keys.timing) ?? "") ?? .liveThenSettle }
        set { store(newValue.rawValue, Keys.timing) }
    }

    /// How many lines fill one caption box before it is cleared.
    public var linesPerBox: Int {
        get { defaults.object(forKey: Keys.linesPerBox) as? Int ?? 2 }
        set { store(newValue, Keys.linesPerBox) }
    }

    /// How many lines of translation to show under the original, 1….
    public var translationLines: Int {
        get { defaults.object(forKey: Keys.translationLines) as? Int ?? 2 }
        set { store(newValue, Keys.translationLines) }
    }

    /// Opacity of the caption box background, 0…1.
    public var boxOpacity: Double {
        get { defaults.object(forKey: Keys.boxOpacity) as? Double ?? 0.55 }
        set { store(newValue, Keys.boxOpacity) }
    }

    public var showSourceAppName: Bool {
        get { defaults.object(forKey: Keys.showSourceApp) as? Bool ?? false }
        set { store(newValue, Keys.showSourceApp) }
    }

    // MARK: - History

    /// How many past boxes to rewind into. `Int.max` means "all".
    public var historyDepth: Int {
        get {
            let raw = defaults.object(forKey: Keys.historyDepth) as? Int ?? 20
            return raw <= 0 ? Int.max : raw
        }
        set { store(newValue, Keys.historyDepth) }
    }

    /// Vertical gap between stacked history boxes.
    public var historySpacing: Double {
        get { defaults.object(forKey: Keys.historySpacing) as? Double ?? 8 }
        set { store(newValue, Keys.historySpacing) }
    }

    /// Seconds of silence before the history stack is forgotten. 0 disables.
    public var historyTimeout: Double {
        get { defaults.object(forKey: Keys.historyTimeout) as? Double ?? 30 }
        set { store(newValue, Keys.historyTimeout) }
    }

    // MARK: - Model behaviour

    /// Drop non-speech audio (music, noise) before it reaches the recogniser.
    public var skipNonSpeech: Bool {
        get { defaults.object(forKey: Keys.skipNonSpeech) as? Bool ?? true }
        set { store(newValue, Keys.skipNonSpeech) }
    }

    /// Start a new caption box when the speaker changes.
    public var newBoxOnSpeakerChange: Bool {
        get { defaults.object(forKey: Keys.newBoxOnSpeaker) as? Bool ?? false }
        set { store(newValue, Keys.newBoxOnSpeaker) }
    }

    /// Seconds after the last new text before the live box fades out.
    public var fadeDelay: Double {
        get { defaults.object(forKey: Keys.fadeDelay) as? Double ?? 4 }
        set { store(newValue, Keys.fadeDelay) }
    }

    // MARK: - Overlay position

    public var overlayOrigin: String? {
        get { defaults.string(forKey: Keys.overlayOrigin) }
        set { store(newValue, Keys.overlayOrigin) }
    }

    // MARK: - Shortcut

    /// Start/stop shortcut, stored as a virtual key code + Carbon modifiers.
    public var keyboardShortcut: HotKeyShortcut {
        get {
            let code = defaults.object(forKey: Keys.shortcutKeyCode) as? Int
            let mods = defaults.object(forKey: Keys.shortcutModifiers) as? Int
            guard let code, let mods else { return .default }
            let shortcut = HotKeyShortcut(
                keyCode: UInt32(code),
                carbonModifiers: UInt32(mods)
            )
            return shortcut.isValid ? shortcut : .default
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Keys.shortcutKeyCode)
            defaults.set(Int(newValue.carbonModifiers), forKey: Keys.shortcutModifiers)
            objectWillChange.send()
        }
    }

    // MARK: - Model engines

    /// Whether translation and summarising run on this Mac or in the cloud.
    public var translationEngine: ModelEngine {
        get { ModelEngine(rawValue: defaults.string(forKey: Keys.translationEngine) ?? "") ?? .local }
        set { store(newValue.rawValue, Keys.translationEngine) }
    }

    public var summaryEngine: ModelEngine {
        get { ModelEngine(rawValue: defaults.string(forKey: Keys.summaryEngine) ?? "") ?? .local }
        set { store(newValue.rawValue, Keys.summaryEngine) }
    }

    /// Base URL of an OpenAI-compatible endpoint, e.g. https://api.openai.com/v1
    public var cloudBaseURL: String {
        get { defaults.string(forKey: Keys.cloudBaseURL) ?? "" }
        set { store(newValue, Keys.cloudBaseURL) }
    }

    /// Model used for cloud translation, e.g. gpt-4o-mini.
    public var cloudTranslationModel: String {
        get { defaults.string(forKey: Keys.cloudTranslationModel) ?? "" }
        set { store(newValue, Keys.cloudTranslationModel) }
    }

    /// Model used for cloud summarising.
    public var cloudSummaryModel: String {
        get { defaults.string(forKey: Keys.cloudSummaryModel) ?? "" }
        set { store(newValue, Keys.cloudSummaryModel) }
    }

    /// Overlay size as "width,height". `nil` means the default size.
    public var overlaySize: String? {
        get { defaults.string(forKey: Keys.overlaySize) }
        set { store(newValue, Keys.overlaySize) }
    }

    // MARK: - Keys

    private enum Keys {
        static let source = "source"
        static let excluded = "excludedBundleIDs"
        static let recognitionLang = "recognitionLanguage"
        static let translationTarget = "translationTarget"
        static let showBoth = "showBothLanguages"
        static let speak = "speakMode"
        static let duck = "lowerOriginalWhileSpeaking"
        static let fontSize = "fontSize"
        static let alignment = "alignment"
        static let timing = "captionTiming"
        static let linesPerBox = "linesPerBox"
        static let translationLines = "translationLines"
        static let boxOpacity = "boxOpacity"
        static let showSourceApp = "showSourceAppName"
        static let historyDepth = "historyDepth"
        static let historySpacing = "historySpacing"
        static let historyTimeout = "historyTimeout"
        static let skipNonSpeech = "skipNonSpeech"
        static let newBoxOnSpeaker = "newBoxOnSpeakerChange"
        static let fadeDelay = "fadeDelay"
        static let overlayOrigin = "overlayOrigin"
        static let overlaySize = "overlaySize"
        static let translationEngine = "translationEngine"
        static let summaryEngine = "summaryEngine"
        static let shortcutKeyCode = "shortcutKeyCode"
        static let shortcutModifiers = "shortcutModifiers"
        static let cloudBaseURL = "cloudBaseURL"
        static let cloudTranslationModel = "cloudTranslationModel"
        static let cloudSummaryModel = "cloudSummaryModel"
    }
}
