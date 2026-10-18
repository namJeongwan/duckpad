import DuckpadLocalization
import AppKit

@MainActor
struct CommandPaletteCommand {
    let item: NSMenuItem
    let path: String
    let isEnabled: Bool
    private let targetReference: CommandPaletteTargetReference

    init(item: NSMenuItem, path: String, isEnabled: Bool, target: AnyObject) {
        self.item = item
        self.path = path
        self.isEnabled = isEnabled
        targetReference = CommandPaletteTargetReference(target)
    }

    var title: String { item.title }
    var qualifiedTitle: String { path.isEmpty ? title : "\(path) › \(title)" }
    var target: AnyObject? { targetReference.value }

    var shortcut: String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let modifiers = item.keyEquivalentModifierMask
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.command) { value += "⌘" }
        let key = item.keyEquivalent.count == 1
            ? item.keyEquivalent.uppercased()
            : item.keyEquivalent
        return value + key
    }
}

@MainActor
private final class CommandPaletteTargetReference {
    weak var value: AnyObject?

    init(_ value: AnyObject) { self.value = value }
}

@MainActor
enum CommandPaletteRegistry {
    static func commands(
        in menu: NSMenu,
        excludingAction: Selector? = nil,
        targetResolver: ((Selector, NSMenuItem) -> AnyObject?)? = nil
    ) -> [CommandPaletteCommand] {
        var commands: [CommandPaletteCommand] = []
        let resolve = targetResolver ?? { action, item in
            (item.target ?? NSApplication.shared.target(forAction: action, to: nil, from: item)) as AnyObject?
        }
        appendCommands(
            from: menu,
            path: "",
            excludingAction: excludingAction,
            targetResolver: resolve,
            to: &commands
        )
        return commands
    }

    static func isCurrentlyEnabled(_ command: CommandPaletteCommand) -> Bool {
        guard let target = command.target else { return false }
        return (target as? NSMenuItemValidation)?.validateMenuItem(command.item)
            ?? command.item.isEnabled
    }

    private static func appendCommands(
        from menu: NSMenu,
        path: String,
        excludingAction: Selector?,
        targetResolver: (Selector, NSMenuItem) -> AnyObject?,
        to commands: inout [CommandPaletteCommand]
    ) {
        for item in menu.items where !item.isHidden && !item.isSeparatorItem {
            if let submenu = item.submenu {
                let component = item.title.isEmpty ? submenu.title : item.title
                let childPath = component.isEmpty
                    ? path
                    : (path.isEmpty ? component : "\(path) › \(component)")
                appendCommands(
                    from: submenu,
                    path: childPath,
                    excludingAction: excludingAction,
                    targetResolver: targetResolver,
                    to: &commands
                )
                continue
            }
            guard let action = item.action, action != excludingAction else { continue }
            guard let target = targetResolver(action, item) else { continue }
            let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item)
                ?? item.isEnabled
            commands.append(CommandPaletteCommand(
                item: item,
                path: path,
                isEnabled: enabled,
                target: target
            ))
        }
    }
}

@MainActor
struct CommandPaletteSearch {
    static func matchingIndices(
        in commands: [CommandPaletteCommand],
        query: String
    ) -> [Int] {
        let terms = folded(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return Array(commands.indices) }
        let phrase = terms.joined(separator: " ")

        return commands.indices.compactMap { index -> (Int, Int)? in
            let command = commands[index]
            let title = folded(command.title)
            let searchable = "\(title) \(folded(MenuLocalization.sourceKey(for: command.item) ?? "")) \(folded(command.path)) \(folded(command.shortcut))"
            guard terms.allSatisfy(searchable.contains) else { return nil }
            let tier: Int
            if title == phrase { tier = 0 }
            else if title.hasPrefix(phrase) { tier = 1 }
            else if title.contains(phrase) { tier = 2 }
            else { tier = 3 }
            return (index, tier)
        }
        .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 < rhs.1 }
        .map(\.0)
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
