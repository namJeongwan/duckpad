import AppKit
import DuckpadDomain

@MainActor
enum LanguageMenuBuilder {
    static func append(
        _ definitions: [LanguageDefinition],
        to menu: NSMenu,
        makeItem: (LanguageDefinition) -> NSMenuItem
    ) {
        let buckets = Dictionary(grouping: definitions) { definition in
            definition.displayName.first.map { String($0).uppercased() } ?? "#"
        }
        for title in buckets.keys.sorted() {
            let definitions = buckets[title, default: []].sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            guard definitions.count > 1 else {
                if let definition = definitions.first { menu.addItem(makeItem(definition)) }
                continue
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            definitions.forEach { submenu.addItem(makeItem($0)) }
            parent.submenu = submenu
            menu.addItem(parent)
        }
    }
}
