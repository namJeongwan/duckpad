import Foundation
import DuckpadDomain

public enum L10n {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var catalog = LocalizationCatalog(language: .english)
    }
    private static let storage = Storage()

    public static var catalog: LocalizationCatalog {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.catalog
    }

    /// Called after settings load and after an app-language preference change.
    /// Existing app-owned UI must then refresh its strings. Native file panels
    /// retain their launch language until the next process launch.
    public static func configure(language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        let catalog = LocalizationCatalog(language: language, preferredLanguages: preferredLanguages)
        storage.lock.lock()
        storage.catalog = catalog
        storage.lock.unlock()
    }

    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        catalog.text(key, arguments: arguments)
    }

    public static func argument<T>(_ value: T) -> String {
        if let number = value as? Int { return number.formatted(.number.locale(catalog.locale)) }
        if let number = value as? UInt64 { return number.formatted(.number.locale(catalog.locale)) }
        return String(describing: value)
    }
}
