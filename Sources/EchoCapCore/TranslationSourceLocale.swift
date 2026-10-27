import Foundation

/// Picks a source locale Apple Translation can actually work with.
///
/// Speech recognition runs on a multilingual model whose locale is `mul_IN` —
/// a macrolanguage placeholder that means "detect whatever you hear". Passing
/// that straight to Translation makes it hang forever in `prepareTranslation`,
/// so anything without a real language code falls back to English.
public enum TranslationSourceLocale {

    /// - Parameters:
    ///   - recognised: the locale the recogniser is running with.
    ///   - detected: a language we noticed in the audio, if any.
    public static func resolve(
        recognised: Locale.Language?,
        detected: Locale.Language?
    ) -> Locale.Language {
        if let recognised, isConcrete(recognised) {
            return recognised
        }
        if let detected, isConcrete(detected) {
            return detected
        }
        return Locale.Language(identifier: "en")
    }

    /// Whether the language is something a translator can be handed.
    ///
    /// `mul` (macrolanguage) and unknown codes are not.
    public static func isConcrete(_ language: Locale.Language) -> Bool {
        guard let code = language.languageCode?.identifier else { return false }
        guard code != "mul", code.count == 2, code.allSatisfy(\.isLowercase) else {
            return false
        }
        return true
    }
}
