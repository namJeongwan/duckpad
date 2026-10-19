import AppKit

/// One stable command entry can appear in more than one native menu.
@MainActor
final class ShortcutRegistry {
    struct Entry {
        let id: String
        let title: String
        let path: String
        let items: [NSMenuItem]
        let defaultIdentities: Set<ShortcutIdentity>
        var identities: Set<ShortcutIdentity> { Set(items.compactMap(Self.identity)) }
        static func identity(for item: NSMenuItem) -> ShortcutIdentity? {
            guard !item.keyEquivalent.isEmpty else { return nil }
            return ShortcutIdentity(key: item.keyEquivalent.lowercased(), modifiers: item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]).rawValue)
        }
        var displayShortcut: String {
            guard let item = items.first, !item.keyEquivalent.isEmpty else { return "" }
            return MenuShortcut.display(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
        }
    }
    let entries: [Entry]
    let overrides: [String: String]
    private(set) var suppressedDefaults: Set<ShortcutIdentity> = []

    init(menu: NSMenu, overrides: [String: String]) {
        self.overrides = overrides
        var collected: [(String, String, NSMenuItem)] = []
        func visit(_ menu: NSMenu, path: String) {
            for item in menu.items where !item.isSeparatorItem {
                if let child = item.submenu {
                    visit(child, path: path.isEmpty ? child.title : "\(path) › \(child.title)")
                } else if let action = item.action, item.tag == 0,
                          item.representedObject == nil || item.representedObject is String {
                    let parameter = item.representedObject as? String
                    let id = NSStringFromSelector(action) + (parameter.map { "|" + $0 } ?? "")
                    collected.append((id, path, item))
                }
            }
        }
        visit(menu, path: "")
        var ids: [String] = []
        var groups: [String: [(String, NSMenuItem)]] = [:]
        for (id, path, item) in collected {
            if groups[id] == nil { ids.append(id) }
            groups[id, default: []].append((path, item))
        }
        entries = ids.compactMap { id in
            guard let group = groups[id], let first = group.first else { return nil }
            let keyed = group.first { !$0.1.keyEquivalent.isEmpty } ?? first
            return Entry(id: id, title: first.1.title, path: first.0,
                         items: [keyed.1] + group.map(\.1).filter { $0 !== keyed.1 },
                         defaultIdentities: Set(group.compactMap { Entry.identity(for: $0.1) }))
        }
        // Remove overridden defaults before assigning replacements, so swaps work.
        for entry in entries where overrides[entry.id] != nil {
            for item in entry.items { item.keyEquivalent = ""; item.keyEquivalentModifierMask = [] }
        }
        var occupied = Set(entries.flatMap(\.identities))
        for entry in entries {
            guard let declaration = overrides[entry.id], !declaration.isEmpty,
                  let shortcut = MenuShortcut(declaration), occupied.insert(shortcut.identity).inserted else { continue }
            entry.items.first?.keyEquivalent = shortcut.keyEquivalent
            entry.items.first?.keyEquivalentModifierMask = shortcut.modifiers
        }
        let active = Set(entries.flatMap(\.identities))
        for entry in entries where overrides[entry.id] != nil {
            suppressedDefaults.formUnion(entry.defaultIdentities.subtracting(active))
        }
    }

    func conflict(for declaration: String, excluding id: String) -> Entry? {
        guard let shortcut = MenuShortcut(declaration) else { return nil }
        return entries.first { $0.id != id && $0.identities.contains(shortcut.identity) }
    }
}
