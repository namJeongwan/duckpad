import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

extension TabSnapshot {
    public var displayTitle: String { localizedTitle(catalog: L10n.catalog) }

    public func localizedTitle(catalog: LocalizationCatalog) -> String {
        // Never infer generated names from a filename or an old persisted title.
        guard fullPath == nil else { return title }
        return LocalizedDocumentTitle.text(title, generated: generatedTitle, catalog: catalog)
    }
}

extension OpenDocumentComparison.Document {
    var displayTitle: String { localizedTitle(catalog: L10n.catalog) }
    func localizedTitle(catalog: LocalizationCatalog) -> String {
        guard fullPath == nil else { return title }
        return LocalizedDocumentTitle.text(title, generated: generatedTitle, catalog: catalog)
    }
}

enum LocalizedDocumentTitle {
    static func text(_ title: String, generated: GeneratedDocumentTitle?, catalog: LocalizationCatalog) -> String {
        switch generated {
        case .untitled(let number):
            return catalog.text("new %1$@", arguments: [number.formatted(.number.locale(catalog.locale))])
        case .restored(let original):
            return catalog.text("%1$@ (restored)", arguments: [original])
        case nil:
            return title
        }
    }
}
