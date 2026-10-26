import Foundation

/// The languages the app can recognise and translate between.
///
/// The recognition side is limited by what Apple's on-device Speech framework
/// offers; the translation side is limited by Apple's Translation framework.
/// Both are checked at runtime and unavailable combinations are shown greyed out.
public enum LanguageCatalog {
    public struct Language: Identifiable, Hashable, Sendable {
        public let id: String          // BCP-47 identifier, e.g. "zh-Hans"
        public let displayName: String  // native name
        public let englishName: String

        public init(id: String, displayName: String, englishName: String) {
            self.id = id
            self.displayName = displayName
            self.englishName = englishName
        }

        public var locale: Locale { Locale(identifier: id) }
        public var language: Locale.Language { Locale.Language(identifier: id) }
    }

    /// The 18 languages the product promises, in the product's own order.
    public static let supported: [Language] = [
        Language(id: "en-US", displayName: "English", englishName: "English"),
        Language(id: "es-ES", displayName: "Español", englishName: "Spanish"),
        Language(id: "fr-FR", displayName: "Français", englishName: "French"),
        Language(id: "it-IT", displayName: "Italiano", englishName: "Italian"),
        Language(id: "pt-PT", displayName: "Português", englishName: "Portuguese"),
        Language(id: "de-DE", displayName: "Deutsch", englishName: "German"),
        Language(id: "nl-NL", displayName: "Nederlands", englishName: "Dutch"),
        Language(id: "tr-TR", displayName: "Türkçe", englishName: "Turkish"),
        Language(id: "ru-RU", displayName: "Русский", englishName: "Russian"),
        Language(id: "ar-SA", displayName: "العربية", englishName: "Arabic"),
        Language(id: "hi-IN", displayName: "हिन्दी", englishName: "Hindi"),
        Language(id: "ja-JP", displayName: "日本語", englishName: "Japanese"),
        Language(id: "ko-KR", displayName: "한국어", englishName: "Korean"),
        Language(id: "vi-VN", displayName: "Tiếng Việt", englishName: "Vietnamese"),
        Language(id: "uk-UA", displayName: "Українська", englishName: "Ukrainian"),
        Language(id: "zh-Hans", displayName: "中文", englishName: "Chinese"),
        Language(id: "pl-PL", displayName: "Polski", englishName: "Polish"),
        Language(id: "sv-SE", displayName: "Svenska", englishName: "Swedish"),
    ]

    /// Experimental languages, offered but marked as such.
    public static let experimental: [Language] = [
        Language(id: "da-DK", displayName: "Dansk", englishName: "Danish"),
        Language(id: "nb-NO", displayName: "Norsk", englishName: "Norwegian"),
    ]

    public static var all: [Language] { supported + experimental }

    /// Look up a language by its identifier.
    public static func language(for id: String) -> Language? {
        all.first { $0.id == id }
    }

    /// Languages that can be recognised right now, based on what the Speech
    /// framework has installed on this machine.
    public static func recognitionLanguages(installed: [Locale]) -> [Language] {
        let installedIDs = Set(installed.map { $0.identifier })
        return all.filter { language in
            installedIDs.contains(language.id)
                || installed.contains { $0.language.languageCode == language.language.languageCode }
        }
    }
}
