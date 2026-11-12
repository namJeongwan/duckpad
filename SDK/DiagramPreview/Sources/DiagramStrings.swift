import Foundation

@MainActor final class DiagramStrings {
    private let bundle: Bundle
    let name: String
    var language: String
    init(directory: URL, language: String, name: String) {
        bundle = Bundle(url: directory) ?? .main; self.language = language; self.name = name
    }
    func format(_ key: String, _ arguments: CVarArg...) -> String { String(format: text(key), arguments: arguments) }
    func text(_ key: String) -> String {
        let fallback = NSLocalizedString(key, tableName: "locale-en", bundle: bundle, value: key, comment: "")
        return NSLocalizedString(key, tableName: "locale-" + language, bundle: bundle, value: fallback, comment: "")
    }
}
