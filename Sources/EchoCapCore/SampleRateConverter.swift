import Foundation

/// Converts the tap's native 48 kHz stereo signal into the 16 kHz mono stream
/// the Speech framework wants.
///
/// 48 kHz → 16 kHz is an exact 3:1 decimation, so a single low-pass FIR stage
/// is enough to reject anything that would alias into the speech band.
///
/// The output is Int16 because that is the format Apple's Speech framework
/// asks for — see `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`.
public final class SampleRateConverter {
    private let decimationFactor: Int
    private let filter: [Float]

    /// Taps of the anti-alias filter, designed for a Blackman window.
    private static let filterTaps = 63

    public init(inputRate: Double = 48_000, outputRate: Double = 16_000) {
        let factor = max(1, Int((inputRate / outputRate).rounded()))
        self.decimationFactor = factor
        self.filter = Self.designLowPass(
            taps: Self.filterTaps,
            cutoffNormalized: 0.5 / Double(factor)   // just under the output Nyquist
        )
    }

    /// Number of output samples produced per `decimationFactor` input frames.
    public var factor: Int { decimationFactor }

    /// Convert interleaved input frames to mono 16 kHz Int16 output samples.
    ///
    /// - Parameters:
    ///   - input: interleaved samples.
    ///   - channelCount: how many channels are interleaved in `input`.
    ///   - frameCount: number of frames (samples per channel) in `input`.
    /// - Returns: downsampled mono samples.
    public func process(_ input: [Float], channelCount: Int, frameCount: Int) -> [Int16] {
        guard frameCount > 0, channelCount > 0 else { return [] }

        // Downmix to mono first — cheaper, and speech is mono anyway.
        var mono = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            for i in 0..<frameCount { mono[i] = input[i] }
        } else {
            let scale = 1.0 / Float(channelCount)
            for f in 0..<frameCount {
                var sum: Float = 0
                let base = f * channelCount
                for c in 0..<channelCount { sum += input[base + c] }
                mono[f] = sum * scale
            }
        }

        // Filter, keeping every `factor`-th sample.
        let half = filter.count / 2
        var out = [Int16]()
        out.reserveCapacity(frameCount / decimationFactor + 1)

        for frame in stride(from: 0, to: frameCount, by: decimationFactor) {
            var acc: Float = 0
            var weight: Float = 0
            for k in 0..<filter.count {
                let idx = frame + k - half
                guard idx >= 0 && idx < frameCount else { continue }
                acc += mono[idx] * filter[k]
                weight += filter[k]
            }
            let value = weight != 0 ? acc / weight : 0
            out.append(Self.toInt16(value))
        }
        return out
    }

    /// Convert a normalised sample to Int16, clamping instead of wrapping.
    public static func toInt16(_ value: Float) -> Int16 {
        let scaled = value * 32767
        if scaled > 32767 { return 32767 }
        if scaled < -32768 { return -32768 }
        return Int16(scaled)
    }

    /// Windowed-sinc low-pass. `cutoffNormalized` is relative to the input Nyquist.
    static func designLowPass(taps: Int, cutoffNormalized: Double) -> [Float] {
        guard taps > 1 else { return [1] }
        let n = Double(taps - 1)
        let fc = cutoffNormalized
        var h = [Float](repeating: 0, count: taps)

        for i in 0..<taps {
            let m = Double(i) - n / 2
            let sinc: Double = m == 0 ? 2 * fc : sin(2 * .pi * fc * m) / (.pi * m)
            // Blackman window
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / n) + 0.08 * cos(4 * .pi * Double(i) / n)
            h[i] = Float(sinc * w)
        }

        // Normalise so DC gain is 1.
        let sum = h.reduce(0, +)
        if sum != 0 { for i in 0..<taps { h[i] /= sum } }
        return h
    }
}
