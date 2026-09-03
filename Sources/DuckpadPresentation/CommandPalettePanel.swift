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
enum CommandPalettePresentationPolicy {
    static func popoverAnimates(reduceMotion: Bool) -> Bool { !reduceMotion }
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
            let searchable = "\(title) \(folded(command.path)) \(folded(command.shortcut))"
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

@MainActor
final class CommandPalettePanel: NSObject,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate
{
    var onExecute: ((NSMenuItem, AnyObject) -> Void)?

    private(set) var commands: [CommandPaletteCommand] = []
    private(set) var filteredIndices: [Int] = []
    private let searchField = NSSearchField(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "No matching commands")
    private let countLabel = NSTextField(labelWithString: "")
    private let contentController = NSViewController()
    private let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 390))
    private var popover: NSPopover?
    private weak var hostWindow: NSWindow?

    var isPresented: Bool { popover?.isShown == true }
    var filteredCommands: [CommandPaletteCommand] { filteredIndices.map { commands[$0] } }

    override init() {
        super.init()
        rootView.setAccessibilityIdentifier("duckpad.commands.panel")

        searchField.placeholderString = "Search commands"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("duckpad.commands.search")
        searchField.setAccessibilityLabel("Search Duckpad commands")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)
        tableView.setAccessibilityIdentifier("duckpad.commands.results")
        tableView.setAccessibilityLabel("Duckpad command search results")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.setAccessibilityIdentifier("duckpad.commands.empty")

        countLabel.textColor = .tertiaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(searchField)
        rootView.addSubview(scrollView)
        rootView.addSubview(emptyLabel)
        rootView.addSubview(countLabel)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -4),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
            countLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            countLabel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -8),
            countLabel.heightAnchor.constraint(equalToConstant: 13),
        ])
        contentController.view = rootView
    }

    func apply(menu: NSMenu, excludingAction: Selector? = nil) {
        commands = CommandPaletteRegistry.commands(in: menu, excludingAction: excludingAction)
        refilter()
    }

    func refreshIfPresented(menu: NSMenu, excludingAction: Selector?) {
        guard isPresented else { return }
        apply(menu: menu, excludingAction: excludingAction)
    }

    func present(menu: NSMenu, excludingAction: Selector?, relativeTo positioningView: NSView) {
        guard let window = positioningView.window else { return }
        searchField.stringValue = ""
        apply(menu: menu, excludingAction: excludingAction)
        stopObservingHostWindow()
        hostWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        if popover?.isShown != true {
            let next = NSPopover()
            next.behavior = .transient
            next.animates = CommandPalettePresentationPolicy.popoverAnimates(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
            next.delegate = self
            next.contentSize = rootView.frame.size
            next.contentViewController = contentController
            popover = next
            next.show(relativeTo: positioningView.bounds, of: positioningView, preferredEdge: .minY)
        }
        contentController.view.window?.makeFirstResponder(searchField)
    }

    func dismiss() {
        stopObservingHostWindow()
        let closing = popover
        popover = nil
        closing?.close()
    }

    func setQuery(_ query: String) {
        searchField.stringValue = query
        refilter()
    }

    func selectResult(at index: Int) {
        guard filteredIndices.indices.contains(index) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    func activateSelectedResult() { activateSelection() }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredIndices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredIndices.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("CommandPaletteCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        let command = commands[filteredIndices[row]]
        let enabled = CommandPaletteRegistry.isCurrentlyEnabled(command)
        cell.textField?.stringValue = command.title
        cell.textField?.textColor = enabled ? .labelColor : .disabledControlTextColor
        cell.toolTip = command.qualifiedTitle
        cell.setAccessibilityLabel(command.qualifiedTitle)
        cell.setAccessibilityValue(enabled ? "Available" : "Unavailable")
        if let detail = cell.viewWithTag(42) as? NSTextField { detail.stringValue = command.path }
        if let shortcut = cell.viewWithTag(43) as? NSTextField { shortcut.stringValue = command.shortcut }
        return cell
    }

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        if let closed = notification.object as? NSPopover, popover === closed { popover = nil }
        stopObservingHostWindow()
        searchField.stringValue = ""
    }

    @objc private func hostWindowWillClose(_ notification: Notification) { dismiss() }

    @objc private func activateSelection() {
        let row = tableView.selectedRow
        guard filteredIndices.indices.contains(row) else { return }
        let command = commands[filteredIndices[row]]
        guard let target = command.target,
              CommandPaletteRegistry.isCurrentlyEnabled(command) else {
            NSSound.beep()
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            return
        }
        dismiss()
        onExecute?(command.item, target)
    }

    private func refilter() {
        filteredIndices = CommandPaletteSearch.matchingIndices(in: commands, query: searchField.stringValue)
        tableView.reloadData()
        emptyLabel.isHidden = !filteredIndices.isEmpty
        countLabel.stringValue = "\(filteredIndices.count) of \(commands.count) commands"
        if !filteredIndices.isEmpty { selectResult(at: 0) }
    }

    private func moveSelection(by offset: Int) {
        guard !filteredIndices.isEmpty else { return }
        let current = max(0, tableView.selectedRow)
        selectResult(at: min(max(0, current + offset), filteredIndices.count - 1))
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(frame: .zero)
        cell.identifier = identifier
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(labelWithString: "")
        detail.tag = 42
        detail.textColor = .tertiaryLabelColor
        detail.font = .systemFont(ofSize: 10)
        detail.lineBreakMode = .byTruncatingMiddle
        detail.translatesAutoresizingMaskIntoConstraints = false
        let shortcut = NSTextField(labelWithString: "")
        shortcut.tag = 43
        shortcut.textColor = .secondaryLabelColor
        shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcut.alignment = .right
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = title
        cell.addSubview(title)
        cell.addSubview(detail)
        cell.addSubview(shortcut)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -8),
            shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            shortcut.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        return cell
    }

    private func stopObservingHostWindow() {
        if let hostWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: hostWindow
            )
        }
        hostWindow = nil
    }
}
