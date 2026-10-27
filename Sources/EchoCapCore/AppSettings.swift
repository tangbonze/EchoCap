import Foundation

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
public final class AppSettings: @unchecked Sendable {
    public static let shared = AppSettings()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Audio

    public var source: AudioSource {
        get { AudioSource(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .systemAudio }
        set { defaults.set(newValue.rawValue, forKey: Keys.source) }
    }

    /// Bundle identifiers excluded from system-audio capture.
    public var excludedBundleIDs: Set<String> {
        get {
            let raw = defaults.stringArray(forKey: Keys.excluded) ?? []
            return Set(raw)
        }
        set { defaults.set(Array(newValue).sorted(), forKey: Keys.excluded) }
    }

    /// Recogniser language; `nil` means auto-detect.
    public var recognitionLanguage: String? {
        get { defaults.string(forKey: Keys.recognitionLang) }
        set { defaults.set(newValue, forKey: Keys.recognitionLang) }
    }

    // MARK: - Translation

    /// Target language for translation; `nil` disables translation.
    public var translationTarget: String? {
        get { defaults.string(forKey: Keys.translationTarget) }
        set { defaults.set(newValue, forKey: Keys.translationTarget) }
    }

    public var showBothLanguages: Bool {
        get { defaults.object(forKey: Keys.showBoth) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showBoth) }
    }

    public var speakMode: SpeakMode {
        get { SpeakMode(rawValue: defaults.string(forKey: Keys.speak) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Keys.speak) }
    }

    /// Duck the original audio while the translation is being spoken.
    public var lowerOriginalWhileSpeaking: Bool {
        get { defaults.object(forKey: Keys.duck) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.duck) }
    }

    // MARK: - Appearance

    public var fontSize: Double {
        get { defaults.object(forKey: Keys.fontSize) as? Double ?? 28 }
        set { defaults.set(newValue, forKey: Keys.fontSize) }
    }

    public var alignment: CaptionAlignment {
        get { CaptionAlignment(rawValue: defaults.string(forKey: Keys.alignment) ?? "") ?? .start }
        set { defaults.set(newValue.rawValue, forKey: Keys.alignment) }
    }

    public var timing: CaptionTiming {
        get { CaptionTiming(rawValue: defaults.string(forKey: Keys.timing) ?? "") ?? .liveThenSettle }
        set { defaults.set(newValue.rawValue, forKey: Keys.timing) }
    }

    /// How many lines fill one caption box before it is cleared.
    public var linesPerBox: Int {
        get { defaults.object(forKey: Keys.linesPerBox) as? Int ?? 2 }
        set { defaults.set(newValue, forKey: Keys.linesPerBox) }
    }

    /// How many lines of translation to show under the original, 1….
    public var translationLines: Int {
        get { defaults.object(forKey: Keys.translationLines) as? Int ?? 2 }
        set { defaults.set(newValue, forKey: Keys.translationLines) }
    }

    /// Opacity of the caption box background, 0…1.
    public var boxOpacity: Double {
        get { defaults.object(forKey: Keys.boxOpacity) as? Double ?? 0.55 }
        set { defaults.set(newValue, forKey: Keys.boxOpacity) }
    }

    public var showSourceAppName: Bool {
        get { defaults.object(forKey: Keys.showSourceApp) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showSourceApp) }
    }

    // MARK: - History

    /// How many past boxes to rewind into. `Int.max` means "all".
    public var historyDepth: Int {
        get {
            let raw = defaults.object(forKey: Keys.historyDepth) as? Int ?? 20
            return raw <= 0 ? Int.max : raw
        }
        set { defaults.set(newValue, forKey: Keys.historyDepth) }
    }

    /// Vertical gap between stacked history boxes.
    public var historySpacing: Double {
        get { defaults.object(forKey: Keys.historySpacing) as? Double ?? 8 }
        set { defaults.set(newValue, forKey: Keys.historySpacing) }
    }

    /// Seconds of silence before the history stack is forgotten. 0 disables.
    public var historyTimeout: Double {
        get { defaults.object(forKey: Keys.historyTimeout) as? Double ?? 30 }
        set { defaults.set(newValue, forKey: Keys.historyTimeout) }
    }

    // MARK: - Model behaviour

    /// Drop non-speech audio (music, noise) before it reaches the recogniser.
    public var skipNonSpeech: Bool {
        get { defaults.object(forKey: Keys.skipNonSpeech) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.skipNonSpeech) }
    }

    /// Start a new caption box when the speaker changes.
    public var newBoxOnSpeakerChange: Bool {
        get { defaults.object(forKey: Keys.newBoxOnSpeaker) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.newBoxOnSpeaker) }
    }

    /// Seconds after the last new text before the live box fades out.
    public var fadeDelay: Double {
        get { defaults.object(forKey: Keys.fadeDelay) as? Double ?? 4 }
        set { defaults.set(newValue, forKey: Keys.fadeDelay) }
    }

    // MARK: - Overlay position

    public var overlayOrigin: String? {
        get { defaults.string(forKey: Keys.overlayOrigin) }
        set { defaults.set(newValue, forKey: Keys.overlayOrigin) }
    }

    /// Overlay size as "width,height". `nil` means the default size.
    public var overlaySize: String? {
        get { defaults.string(forKey: Keys.overlaySize) }
        set { defaults.set(newValue, forKey: Keys.overlaySize) }
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
    }
}
