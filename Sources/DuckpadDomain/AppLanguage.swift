/// Persisted language identifiers; display names are native names so the picker
/// remains usable even when the current interface language is unfamiliar.
public enum AppLanguage: String, CaseIterable, Codable, Equatable, Sendable {
    case system
    case english = "en"
    case korean = "ko"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case brazilianPortuguese = "pt-BR"
    case italian = "it"
    case french = "fr"
    case german = "de"

    public var nativeName: String {
        switch self {
        case .system: "Follow macOS"
        case .english: "English"
        case .korean: "한국어"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        case .brazilianPortuguese: "Português (Brasil)"
        case .italian: "Italiano"
        case .french: "Français"
        case .german: "Deutsch"
        }
    }
}
