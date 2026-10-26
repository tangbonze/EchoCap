import Testing
import Foundation
@testable import EchoCapCore

@Suite("采样率转换")
struct SampleRateConverterTests {

    @Test("48k 降到 16k 是三倍抽取")
    func decimationFactorIsThree() {
        let converter = SampleRateConverter(inputRate: 48_000, outputRate: 16_000)
        #expect(converter.factor == 3)
    }

    @Test("立体声降为单声道")
    func stereoDownmixesToMono() {
        let converter = SampleRateConverter(inputRate: 48_000, outputRate: 16_000)
        // 480 帧立体声：左 0.4 右 0.6 → 单声道 0.5
        var input = [Float]()
        input.reserveCapacity(960)
        for _ in 0..<480 {
            input.append(0.4)
            input.append(0.6)
        }
        let out = converter.process(input, channelCount: 2, frameCount: 480)
        #expect(out.count == 160)
        // 取中间位置，避开滤波器起振的边界效应。
        let mid = out[out.count / 2]
        #expect(abs(Float(mid) / 32767.0 - 0.5) < 0.05)
    }

    @Test("输出长度符合抽取比例")
    func outputLengthMatchesDecimation() {
        let converter = SampleRateConverter(inputRate: 48_000, outputRate: 16_000)
        let input = [Float](repeating: 0.1, count: 480)
        let out = converter.process(input, channelCount: 1, frameCount: 480)
        #expect(out.count == 160)
    }

    @Test("超出量程时钳位而非回绕")
    func int16ConversionClamps() {
        #expect(SampleRateConverter.toInt16(2.0) == 32767)
        #expect(SampleRateConverter.toInt16(-2.0) == -32768)
        #expect(SampleRateConverter.toInt16(0.0) == 0)
    }

    @Test("直流信号经过滤波后保持幅度")
    func dcSignalSurvivesFiltering() {
        let converter = SampleRateConverter(inputRate: 48_000, outputRate: 16_000)
        let input = [Float](repeating: 0.5, count: 480)
        let out = converter.process(input, channelCount: 1, frameCount: 480)
        let mid = out[out.count / 2]
        #expect(abs(Float(mid) / 32767.0 - 0.5) < 0.05)
    }
}
