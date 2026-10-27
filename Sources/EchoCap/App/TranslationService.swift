import Foundation
import Translation
import EchoCapCore

/// Wraps Apple's on-device Translation framework.
///
/// Like the recogniser, translation runs entirely on the machine — nothing is
/// sent to a server, and no language pair needs an account.
///
/// The service is an actor because a `TranslationSession` is stateful: it
/// holds the loaded models for one language pair, and only one translation
/// may use it at a time.
actor TranslationService {
    // `LanguageAvailability` and `TranslationSession` are not `Sendable`, but
    // this actor serialises every access to them, so the isolation is sound.


    enum TranslationError: Error, LocalizedError {
        case unsupportedPair
        case notInstalled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedPair: return "Apple 翻译不支持该语言组合"
            case .notInstalled: return "翻译模型尚未下载"
            case .failed(let message): return "翻译失败：\(message)"
            }
        }
    }

    /// A cached session for one source/target pair.
    private nonisolated(unsafe) var session: TranslationSession?
    private var sessionKey: String?

    private nonisolated(unsafe) let availability = LanguageAvailability()

    /// The language pair currently loaded.
    private(set) var currentPair: (source: Locale.Language, target: Locale.Language)?

    /// Whether results need folding to Simplified Chinese.
    ///
    /// Apple's Chinese model is one model for both scripts and does not honour
    /// the requested variant reliably — the same session will hand back
    /// Simplified for one sentence and Traditional for the next. Folding every
    /// result keeps the captions in one script.
    private var foldToSimplifiedChinese = false

    /// Check whether a translation pair can be used at all.
    func isAvailable(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        let status = await availability.status(from: source, to: target)
        return status == .installed || status == .supported
    }

    /// Configure the service for a language pair. Returns `false` when the pair
    /// is not supported by the system.
    @discardableResult
    func configure(source: Locale.Language, target: Locale.Language) async -> Bool {
        let key = "\(source.maximalIdentifier)->\(target.maximalIdentifier)"
        if sessionKey == key, session != nil { return true }

        guard await isAvailable(from: source, to: target) else {
            session = nil
            sessionKey = nil
            return false
        }

        do {
            let newSession = TranslationSession(installedSource: source, target: target)
            try await newSession.prepareTranslation()
            session = newSession
            sessionKey = key
            currentPair = (source, target)
            foldToSimplifiedChinese = Self.isSimplifiedChinese(target)
            return true
        } catch {
            session = nil
            sessionKey = nil
            return false
        }
    }

    /// Translate `text`. Returns `nil` when translation is not configured.
    func translate(_ text: String) async -> String? {
        guard let session, !text.isEmpty else { return nil }
        do {
            let response = try await session.translate(text)
            return normalise(response.targetText)
        } catch {
            return nil
        }
    }

    /// Translate a batch of strings.
    func translate(batch: [String]) async -> [String] {
        guard let session, !batch.isEmpty else { return [] }
        do {
            let requests = batch.map { TranslationSession.Request(sourceText: $0) }
            let responses = try await session.translations(from: requests)
            return responses.map { normalise($0.targetText) }
        } catch {
            return []
        }
    }

    /// Put a result into the requested script, when the target is Chinese.
    private func normalise(_ text: String) -> String {
        guard foldToSimplifiedChinese else { return text }
        return ChineseScript.toSimplified(text)
    }

    /// Whether `language` asks for Simplified Chinese.
    private static func isSimplifiedChinese(_ language: Locale.Language) -> Bool {
        // An explicit script wins; a bare "zh" is treated as Simplified, which
        // matches what the system does by default.
        let script = language.script?.identifier
        guard language.languageCode?.identifier == "zh" || script == "Hans" || script == "Hant" else {
            return false
        }
        return script != "Hant"
    }

    /// Release the current session.
    func reset() {
        session = nil
        sessionKey = nil
        currentPair = nil
    }
}
