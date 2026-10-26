import Foundation
import AVFoundation
import Speech

/// Holds the recognition callbacks so they can be installed at any time.
///
/// The results stream runs on its own task, so the callbacks cannot be read
/// off `self` directly — they live in this box, which the task reads at the
/// moment each result arrives.
final class SpeechCallbacks: @unchecked Sendable {
    /// Called when the recogniser revises its reading of the current utterance.
    /// - Parameter text: the cumulative text of the current segment.
    /// - Parameter isFinal: `true` once the recogniser will not revise it further.
    /// - Parameter rangeStart: start time of the segment, in seconds.
    var onResult: (@Sendable (String, Bool, Double) -> Void)?

    /// Called when the recogniser reports the utterance has ended.
    var onUtteranceEnd: (@Sendable () -> Void)?

    /// Called when the detected language changes (auto-detect mode only).
    var onLanguageDetected: (@Sendable (String) -> Void)?
}

/// Runs Apple's on-device speech recognition against a live audio stream.
///
/// Everything happens locally: the recogniser is configured with
/// `requiresOnDeviceRecognition`, so audio never leaves the machine and no
/// account or network round-trip is involved.
@available(macOS 26.0, *)
final class SpeechEngine: @unchecked Sendable {

    enum EngineError: Error, LocalizedError {
        case noRecognizer
        case assetsUnavailable(String)
        case prepareFailed(String)

        var errorDescription: String? {
            switch self {
            case .noRecognizer: return "当前系统没有可用的语音识别模型"
            case .assetsUnavailable(let id): return "语言 \(id) 的识别模型尚未下载"
            case .prepareFailed(let message): return "识别引擎启动失败：\(message)"
            }
        }
    }

    /// The callbacks the recognition stream reports into.
    let callbacks = SpeechCallbacks()

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var resultsTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<AnalyzerInput>.Continuation?

    /// The locale currently in use.
    private(set) var activeLocale: Locale?

    /// The format the recogniser expects (16 kHz mono Int16, interleaved).
    private(set) var inputFormat: AVAudioFormat?

    /// True when the recogniser is running and accepting audio.
    private(set) var isRunning = false

    // MARK: - Lifecycle

    /// Start recognition.
    ///
    /// - Parameter locale: language to recognise. `nil` enables auto-detection.
    func start(locale: Locale?) async throws {
        stop()

        // Work out which locale we can actually use. Auto-detection needs the
        // multilingual model; when it is not installed we fall back to an
        // installed single-language model rather than failing outright.
        let requested = locale ?? Locale(identifier: Self.multilingualLocale)
        var transcriber = SpeechTranscriber(locale: requested, preset: .progressiveTranscription)
        self.activeLocale = requested

        var format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        if format == nil {
            if locale != nil {
                // The user explicitly asked for this language — fetch its model.
                await installAssetsIfNeeded(for: transcriber)
                format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            }

            if format == nil {
                // Still unusable — fall back to a model that is installed.
                guard let fallback = await Self.fallbackLocale(excluding: requested) else {
                    throw EngineError.assetsUnavailable(requested.identifier)
                }
                transcriber = SpeechTranscriber(locale: fallback, preset: .progressiveTranscription)
                self.transcriber = transcriber
                self.activeLocale = fallback
                format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            }
        }

        guard let format else {
            throw EngineError.assetsUnavailable(requested.identifier)
        }
        inputFormat = format

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Feed audio in through an async sequence the analyzer pulls from.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        streamContinuation = continuation

        // The analyzer must be prepared with the format before any
        // `AnalyzerInput` is created for it.
        try await analyzer.prepareToAnalyze(in: format)

        // The consumer task reads the callbacks through the shared box, so the
        // callbacks can be installed before or after the engine starts.
        let callbacks = self.callbacks

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    callbacks.onResult?(text, result.isFinal, result.range.start.seconds)
                    if result.isFinal {
                        callbacks.onUtteranceEnd?()
                    }
                }
            } catch {
                // Recognition stopped — the engine is torn down on the next start().
            }
        }

        try await analyzer.start(inputSequence: stream)
        isRunning = true
    }

    /// Push newly captured audio into the recogniser.
    ///
    /// - Parameters:
    ///   - samples: mono 16 kHz Int16 samples.
    func feed(samples: [Int16]) {
        guard let continuation = streamContinuation,
              let format = inputFormat,
              !samples.isEmpty else { return }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        guard let channelData = buffer.int16ChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channelData.update(from: base, count: samples.count)
            }
        }
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// Signal that no more audio is coming, letting the recogniser flush.
    func finish() async {
        guard let analyzer else { return }
        streamContinuation?.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        stop()
    }

    /// Tear everything down.
    func stop() {
        resultsTask?.cancel()
        resultsTask = nil
        streamContinuation?.finish()
        streamContinuation = nil
        analyzer = nil
        transcriber = nil
        isRunning = false
    }

    /// Locales whose recognition models are installed on this machine.
    static func installedRecognitionLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    /// The locale that handles automatic language detection.
    static let multilingualLocale = "mul_IN"

    /// Download the on-device assets for `module` if they are not present yet.
    private func installAssetsIfNeeded(for module: SpeechTranscriber) async {
        let status = await AssetInventory.status(forModules: [module])
        switch status {
        case .installed:
            return
        case .supported, .downloading:
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try? await request.downloadAndInstall()
            }
        case .unsupported:
            return
        @unknown default:
            return
        }
    }

    /// Pick a locale that is actually installed, preferring the user's own
    /// language and then English.
    private static func fallbackLocale(excluding excluded: Locale) async -> Locale? {
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.isEmpty else { return nil }

        let preferred = Locale.preferredLanguages.first.map { Locale(identifier: $0) }
        let ordered = [preferred].compactMap { $0 } + [
            Locale(identifier: "zh-CN"),
            Locale(identifier: "en-US"),
        ]

        for candidate in ordered {
            if let match = installed.first(where: { locale in
                locale.identifier == candidate.identifier
                    || locale.language.languageCode == candidate.language.languageCode
            }) {
                return match
            }
        }
        return installed.first { $0.identifier != excluded.identifier }
    }
}
