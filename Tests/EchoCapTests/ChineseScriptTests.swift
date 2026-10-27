import Testing
import Foundation
@testable import EchoCapCore

@Suite("繁简统一")
struct ChineseScriptTests {

    @Test("繁体结果被折成简体")
    func traditionalIsFolded() {
        let traditional = "敏捷的棕色狐狸跳過了懶惰的狗，清晨的太陽慢慢升起"
        let folded = ChineseScript.toSimplified(traditional)

        #expect(folded == "敏捷的棕色狐狸跳过了懒惰的狗，清晨的太阳慢慢升起")
        #expect(ChineseScript.containsTraditionalCharacters(traditional))
    }

    @Test("本来就是简体的文本保持不变")
    func simplifiedIsUntouched() {
        let simplified = "会议明天早上九点开始。"
        #expect(ChineseScript.toSimplified(simplified) == simplified)
        #expect(ChineseScript.containsTraditionalCharacters(simplified) == false)
    }

    @Test("非中文文本不受影响")
    func otherLanguagesAreUntouched() {
        let english = "The meeting starts at nine."
        #expect(ChineseScript.toSimplified(english) == english)
        #expect(ChineseScript.toSimplified("") == "")
    }

    @Test("同一段里混用两种字形也会被统一")
    func mixedScriptsAreNormalised() {
        // Apple 的模型偶尔会在同一段里换字形。
        let mixed = "跳过了懶惰的狗"
        #expect(ChineseScript.toSimplified(mixed) == "跳过了懒惰的狗")
    }
}
