import Testing
import Foundation
@testable import EchoCapCore

@Suite("噪声文本判定")
struct CaptionTextSanitizerTests {

    @Test("开头那次爆音造成的乱码被识别为噪声")
    func leadingClickNoise() {
        #expect(CaptionTextSanitizer.isNoise("'I\"I'\"\"'.'"))
        #expect(CaptionTextSanitizer.isNoise("\"\"''"))
        #expect(CaptionTextSanitizer.isNoise("..."))
        #expect(CaptionTextSanitizer.isNoise("·"))
    }

    @Test("正常句子不会被误杀")
    func realSentencesSurvive() {
        #expect(!CaptionTextSanitizer.isNoise("The the 1st 5 years would have improved by a factor of 10"))
        #expect(!CaptionTextSanitizer.isNoise("前5年将提高10倍"))
        #expect(!CaptionTextSanitizer.isNoise("OK"))
        #expect(!CaptionTextSanitizer.isNoise("好。"))
        #expect(!CaptionTextSanitizer.isNoise("Yes, sir."))
    }

    @Test("空文本算噪声")
    func emptyIsNoise() {
        #expect(CaptionTextSanitizer.isNoise(""))
        #expect(CaptionTextSanitizer.isNoise("   "))
        #expect(CaptionTextSanitizer.isNoise("\n"))
    }

    @Test("带引号的正常句子仍然保留")
    func quotedSpeechSurvives() {
        #expect(!CaptionTextSanitizer.isNoise("\"Hello there,\" she said."))
    }
}
