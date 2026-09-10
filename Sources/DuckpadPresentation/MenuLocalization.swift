import AppKit
import DuckpadDomain
import DuckpadLocalization

@MainActor
enum MenuLocalization {
    private static var sourceKeyAssociation: UInt8 = 0

    static func sourceKey(for item: NSMenuItem) -> String? {
        objc_getAssociatedObject(item, &sourceKeyAssociation) as? String
    }

    /// Run after native menu assembly. AppKit may supply action-based identifiers;
    /// preserve those and keep the English search name in separate metadata.
    static func apply(to menu: NSMenu, catalog: LocalizationCatalog = L10n.catalog, sourceTitle: String? = nil) {
        let menuKey = sourceTitle ?? menu.title
        for item in menu.items where !item.isSeparatorItem {
            let key = sourceKey(for: item) ?? (item.title.isEmpty ? item.submenu?.title ?? "" : item.title)
            objc_setAssociatedObject(item, &sourceKeyAssociation, key, .OBJC_ASSOCIATION_COPY_NONATOMIC)
            if let submenu = item.submenu {
                item.identifier = NSUserInterfaceItemIdentifier(key)
                apply(to: submenu, catalog: catalog, sourceTitle: key)
            }
            let action = item.action
            let isFile = item.representedObject is URL
            let isLanguage = action == #selector(DuckpadWindowController.performChooseLanguage(_:))
                && item.representedObject as? String != LanguageID.plainText.rawValue
            let isExtension = action == #selector(DuckpadWindowController.performExtensionCommand(_:))
                && !(item.representedObject as? String ?? "").hasPrefix("com.duckpad.text-tools.")
            if !isFile && !isLanguage && !isExtension {
                if let label = item.accessibilityLabel() { item.setAccessibilityLabel(catalog.text(label)) }
                if let help = item.toolTip { item.toolTip = catalog.text(help) }
                item.title = catalog.text(key)
            }
            if let value = item.accessibilityValue() as? String {
                item.setAccessibilityValue(catalog.text(value))
            }
        }
        menu.title = catalog.text(menuKey)
    }
}
