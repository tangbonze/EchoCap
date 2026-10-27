import Foundation
import Translation
import EchoCapCore

/// Translates caption text, either with Apple's on-device Translation framework
/// or with a cloud model the user configured.
///
/// The service is an actor because a `TranslationSession` is stateful: it holds
/// the loaded models for one language pair, and only one translation may use it
/// at a time. The cloud path goes through the same actor, which keeps the number
/// of in-flight requests down to one.
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

    /// Which engine is in use.
    private(set) var engine: ModelEngine = .local

    /// Why the last translation failed, if it did.
    private(set) var lastError: String?

    /// Cloud endpoint, when `engine` is `.cloud`.
    private var cloud = CloudLLMConfig(baseURL: "", apiKey: "", model: "")

    /// English name of the target language, for the cloud prompt.
    private var targetName = ""

    /// Whether results need folding to Simplified Chinese.
    ///
    /// Apple's Chinese model is one model for both scripts and does not honour
    /// the requested variant reliably — the same session hands back Simplified
    /// for one sentence and Traditional for the next. Cloud models have the same
    /// habit, so both paths are folded.
    private var foldToSimplifiedChinese = false

    private let cloudClient = CloudLLMClient()

    // MARK: - Configuration

    /// Check whether a translation pair can be used at all.
    func isAvailable(from source: Locale.Language, to target: Locale.Language) async -> Bool {
        let status = await availability.status(from: source, to: target)
        return status == .installed || status == .supported
    }

    /// Configure the service for a language pair and an engine.
    ///
    /// - Returns: `false` when the chosen engine cannot serve this pair.
    @discardableResult
    func configure(
        source: Locale.Language,
        target: Locale.Language,
        engine: ModelEngine,
        cloud: CloudLLMConfig,
        targetName: String
    ) async -> Bool {
        self.engine = engine
        self.cloud = cloud
        self.targetName = targetName
        foldToSimplifiedChinese = Self.isSimplifiedChinese(target)

        switch engine {
        case .cloud:
            // Nothing to prepare: the endpoint either answers or it does not.
            session = nil
            sessionKey = nil
            currentPair = (source, target)
            return cloud.isConfigured

        case .local:
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
                return true
            } catch {
                session = nil
                sessionKey = nil
                return false
            }
        }
    }

    // MARK: - Translation

    /// Translate `text`. Returns `nil` when translation is not configured.
    func translate(_ text: String) async -> String? {
        guard !text.isEmpty else { return nil }

        switch engine {
        case .cloud:
            guard cloud.isConfigured else { return nil }
            do {
                let reply = try await cloudClient.complete(
                    system: cloudSystemPrompt,
                    user: text,
                    config: cloud
                )
                lastError = nil
                return normalise(reply)
            } catch {
                lastError = error.localizedDescription
                return nil
            }

        case .local:
            guard let session else {
                lastError = "本机翻译会话未就绪"
                return nil
            }
            do {
                let response = try await session.translate(text)
                lastError = nil
                return normalise(response.targetText)
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        }
    }

    /// Translate a batch of strings.
    func translate(batch: [String]) async -> [String] {
        guard !batch.isEmpty else { return [] }

        switch engine {
        case .cloud:
            // One request per item: a batched prompt is harder to split back up.
            var results: [String] = []
            for item in batch {
                results.append(await translate(item) ?? "")
            }
            return results

        case .local:
            guard let session else { return [] }
            do {
                let requests = batch.map { TranslationSession.Request(sourceText: $0) }
                let responses = try await session.translations(from: requests)
                return responses.map { normalise($0.targetText) }
            } catch {
                return []
            }
        }
    }

    /// Release the current session.
    func reset() {
        session = nil
        sessionKey = nil
        currentPair = nil
    }

    // MARK: - Helpers

    private var cloudSystemPrompt: String {
        """
        You are a subtitle translator. Translate the user's text into \(targetName).
        Rules:
        - Output only the translation, with no notes, quotes or explanations.
        - Keep names, numbers and technical terms accurate.
        - Match the register of the original: spoken subtitles stay spoken.
        """
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
}
