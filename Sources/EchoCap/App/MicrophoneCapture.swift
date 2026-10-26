import Foundation
import AVFoundation
import EchoCapCore

/// Captures the microphone using `AVAudioEngine`.
///
/// Mirrors the system-audio path: samples are delivered as 16 kHz mono floats
/// so the recogniser sees exactly the same format either way.
final class MicrophoneCapture {

    var onSamples: (([Int16]) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: SampleRateConverter?
    private var isRunning = false

    /// The sample rate the recogniser expects.
    static let targetSampleRate: Double = 16_000

    func start() throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.microphoneUnavailable
        }
        converter = SampleRateConverter(
            inputRate: inputFormat.sampleRate,
            outputRate: 16_000
        )

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            guard let channelData = buffer.floatChannelData else { return }
            let channels = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let interleaved = Array(UnsafeBufferPointer(start: channelData[0], count: frames * channels))
            let mono = converter.process(interleaved, channelCount: channels, frameCount: frames)
            guard !mono.isEmpty else { return }
            self.onSamples?(mono)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }

    enum CaptureError: Error, LocalizedError {
        case microphoneUnavailable
        var errorDescription: String? {
            switch self {
            case .microphoneUnavailable: return "麦克风不可用"
            }
        }
    }
}
