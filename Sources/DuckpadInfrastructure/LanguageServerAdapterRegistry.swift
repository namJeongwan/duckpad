import Foundation
import DuckpadApplication

/// Only active, authorized plugin registrations enter the client. Competing
/// language owners are quarantined instead of silently replacing one another.
public struct LanguageServerAdapterRegistry: Equatable, Sendable {
    public let registrations: [LanguageServerRegistration]
    public let conflictingLanguages: Set<String>
    public static let empty = Self(registrations: [])
    public init(registrations: [LanguageServerRegistration]) {
        let groups = Dictionary(grouping: registrations, by: { $0.service.languageID })
        conflictingLanguages = Set(groups.filter { $0.value.count > 1 }.keys)
        self.registrations = registrations.filter { $0.service.isValid && groups[$0.service.languageID]?.count == 1 }
            .sorted { $0.settingsKey < $1.settingsKey }
    }
    public func registration(forLanguageID languageID: String) -> LanguageServerRegistration? {
        registrations.first { $0.service.languageID == languageID }
    }
}
