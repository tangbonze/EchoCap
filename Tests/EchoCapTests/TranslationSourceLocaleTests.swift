import Testing
import Foundation
@testable import EchoCapCore

@Suite("翻译源语言")
struct TranslationSourceLocaleTests {

    @Test("多语种占位符不能当源语言")
    func macrolanguageIsRejected() {
        let mul = Locale.Language(identifier: "mul_IN")
        #expect(!TranslationSourceLocale.isConcrete(mul))
    }

    @Test("具体语言可以直接用")
    func concreteLanguagesPass() {
        #expect(TranslationSourceLocale.isConcrete(Locale.Language(identifier: "en")))
        #expect(TranslationSourceLocale.isConcrete(Locale.Language(identifier: "zh-Hans")))
        #expect(TranslationSourceLocale.isConcrete(Locale.Language(identifier: "en-US")))
    }

    @Test("识别语言是多语种时退回检测到的语言")
    func fallsBackToDetected() {
        let resolved = TranslationSourceLocale.resolve(
            recognised: Locale.Language(identifier: "mul_IN"),
            detected: Locale.Language(identifier: "fr")
        )
        #expect(resolved.maximalIdentifier.hasPrefix("fr"))
    }

    @Test("都没有具体语言时退回英文")
    func fallsBackToEnglish() {
        let resolved = TranslationSourceLocale.resolve(
            recognised: Locale.Language(identifier: "mul_IN"),
            detected: nil
        )
        #expect(resolved.languageCode?.identifier == "en")
    }
}
