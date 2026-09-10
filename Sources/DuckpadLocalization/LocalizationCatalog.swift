import Foundation
import DuckpadDomain

/// Immutable, independently testable catalog. Never consults user document data.
public struct LocalizationCatalog: Sendable {
    public let language: AppLanguage
    public let locale: Locale
    private let bundle: Bundle
    private let english: Bundle

    public init(language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.init(language: language, preferredLanguages: preferredLanguages, resources: Self.resources)
    }

    init(language: AppLanguage, preferredLanguages: [String], resources: Bundle) {
        let supported = AppLanguage.allCases.filter { $0 != .system }.map(\.rawValue)
        let resolved = language == .system
            ? Bundle.preferredLocalizations(from: supported, forPreferences: preferredLanguages).first ?? "en"
            : language.rawValue
        self.language = AppLanguage(rawValue: resolved) ?? .english
        locale = Locale(identifier: self.language.rawValue)
        english = Bundle(url: resources.bundleURL.appendingPathComponent("en.lproj")) ?? resources
        bundle = Bundle(url: resources.bundleURL.appendingPathComponent(self.language.rawValue.lowercased() + ".lproj")) ?? english
    }

    public func text(_ key: String, arguments: [CVarArg] = []) -> String {
        let fallback = english.localizedString(forKey: key, value: key, table: nil)
        let format = bundle.localizedString(forKey: key, value: fallback, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }

    private static var resources: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Duckpad_DuckpadLocalization.bundle"),
           let packaged = Bundle(url: url) { return packaged }
        return Bundle.module
    }
}
