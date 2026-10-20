import AppKit
import DuckpadLocalization

/// An in-window overlay: never opens a popover outside the editor's bounds.
@MainActor
final class CommandPaletteView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private static weak var validatingPalette: CommandPaletteView?

    /// Menu validation uses the invoking pane without moving the actual field
    /// editor (which would interrupt search selection and IME composition).
    static func commandResponder(in window: NSWindow?) -> NSResponder? {
        guard let window else { return nil }
        if let palette = validatingPalette, palette.window === window {
            return palette.returnFocus
        }
        return window.firstResponder
    }

    private func withInvocationContext<T>(_ body: () -> T) -> T {
        let previous = Self.validatingPalette
        Self.validatingPalette = self
        defer { Self.validatingPalette = previous }
        return body()
    }

    var onExecute: ((NSMenuItem, AnyObject) -> Void)?
    private let card = NSVisualEffectView()
    private let search = SearchInputField()
    private let searchIcon = NSImageView()
    private let clearButton = StatusBarButton()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private(set) var commands: [CommandPaletteCommand] = []
    private weak var sourceMenu: NSMenu?
    private var excludedAction: Selector?
    private var catalog = L10n.catalog
    private let countLabel = NSTextField(labelWithString: "")
    private(set) var filteredCommands: [CommandPaletteCommand] = []
    private weak var returnFocus: NSResponder?
    private weak var returnControl: NSControl?
    private var returnSelection: NSRange?
    private var keyMonitor: Any?
    var isPresented: Bool { superview != nil }
    var cardFrame: NSRect { card.frame }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        setAccessibilityIdentifier("duckpad.commands")
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.shadow = NSShadow()
        card.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.35)
        card.shadow?.shadowBlurRadius = 20
        card.shadow?.shadowOffset = NSSize(width: 0, height: -6)
        card.layer?.borderWidth = 1
        updateAppearance()
        addSubview(card)
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.setAccessibilityElement(false)
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.target = self
        clearButton.action = #selector(clearQuery)
        clearButton.contentTintColor = .secondaryLabelColor
        card.addSubview(searchIcon)
        card.addSubview(clearButton)
        search.delegate = self
        search.setAccessibilityIdentifier("duckpad.commands.search")
        card.addSubview(search)
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            divider.topAnchor.constraint(equalTo: card.topAnchor, constant: 46),
        ])
        let column = NSTableColumn(identifier: .init("command"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsEmptySelection = false
        table.backgroundColor = .clear
        table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateSelectedResult)
        table.setAccessibilityIdentifier("duckpad.commands.results")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        card.addSubview(scroll)
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        card.addSubview(empty)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        card.addSubview(countLabel)
    }

    required init?(coder: NSCoder) { nil }

    func apply(menu: NSMenu, excludingAction: Selector? = nil) {
        sourceMenu = menu
        excludedAction = excludingAction
        commands = resolveCommands(in: menu)
        refilter()
    }

    private func resolveCommands(in menu: NSMenu) -> [CommandPaletteCommand] {
        withInvocationContext {
            CommandPaletteRegistry.commands(in: menu, excludingAction: excludedAction) { [self] action, item in
                if let target = item.target { return target as AnyObject }
                if isPresented, let previous = commands.first(where: { $0.item === item }), let target = previous.target {
                    return target
                }
                // Resolve newly registered responder-chain commands from the
                // invoking pane, never from the palette's search field.
                var responder = returnFocus
                var visited = Set<ObjectIdentifier>()
                while let current = responder, visited.insert(ObjectIdentifier(current)).inserted {
                    if current.responds(to: action) { return current }
                    responder = current.nextResponder
                }
                if !isPresented { return NSApp.target(forAction: action, to: nil, from: item) as AnyObject? }
                if let delegate = NSApp.delegate, delegate.responds(to: action) { return delegate }
                return NSApp.responds(to: action) ? NSApp : nil
            }
        }
    }

    func refreshIfPresented(menu: NSMenu, excludingAction: Selector?) {
        guard isPresented else { return }
        let selected = filteredCommands.indices.contains(table.selectedRow) ? filteredCommands[table.selectedRow].item : nil
        apply(menu: menu, excludingAction: excludingAction)
        if let selected, let row = filteredCommands.firstIndex(where: { $0.item === selected }) { selectResult(at: row) }
    }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        search.placeholderString = catalog.text("Search commands")
        clearButton.toolTip = catalog.text("Clear Search")
        clearButton.setAccessibilityLabel(catalog.text("Clear Search"))
        search.setAccessibilityLabel(catalog.text("Search Duckpad commands"))
        table.setAccessibilityLabel(catalog.text("Duckpad command search results"))
        empty.stringValue = catalog.text("No matching commands")
        let selection = table.selectedRow
        if let sourceMenu {
            let visibleItems = filteredCommands.map(\.item)
            commands = resolveCommands(in: sourceMenu)
            filteredCommands = visibleItems.compactMap { item in commands.first { $0.item === item } }
        }
        table.reloadData()
        if filteredCommands.indices.contains(selection) { selectResult(at: selection) }
        updateCount()
    }

    func present(menu: NSMenu, excludingAction: Selector?, relativeTo anchor: NSView) {
        guard let host = anchor.window?.contentView else { return }
        present(menu: menu, excludingAction: excludingAction, in: host)
    }

    func present(menu: NSMenu, excludingAction: Selector? = nil, in host: NSView, catalog: LocalizationCatalog = L10n.catalog) {
        dismiss()
        guard let window = host.window else { return }
        // A window has one command surface, regardless of the invoking pane.
        for other in host.subviews.compactMap({ $0 as? CommandPaletteView }) { other.dismiss() }
        returnFocus = window.firstResponder
        if let editor = returnFocus as? NSTextView, editor.isFieldEditor {
            returnControl = editor.delegate as? NSControl
            returnSelection = editor.selectedRange()
        }
        refreshLocalization(catalog: catalog)
        apply(menu: menu, excludingAction: excludingAction)
        frame = host.bounds
        host.addSubview(self, positioned: .above, relativeTo: nil)
        setQuery("")
        layoutSubtreeIfNeeded()
        window.makeFirstResponder(search)
        NotificationCenter.default.addObserver(self, selector: #selector(hostClosed), name: NSWindow.willCloseNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(hostResigned), name: NSWindow.didResignKeyNotification, object: window)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  event.modifierFlags.intersection([.command, .shift, .control, .option]) == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "p" else { return event }
            self.dismiss()
            return nil
        }
    }

    func dismiss(restoreFocus: Bool = true) {
        guard isPresented else { return }
        let hostWindow = window
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: hostWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: hostWindow)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        removeFromSuperview()
        if restoreFocus, let responder = returnControl ?? returnFocus {
            hostWindow?.makeFirstResponder(responder)
            if let selection = returnSelection, let editor = hostWindow?.firstResponder as? NSTextView {
                let count = editor.string.utf16.count
                let location = min(selection.location, count)
                editor.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
            }
        }
        returnFocus = nil
        returnControl = nil
        returnSelection = nil
    }

    @objc private func hostClosed() { dismiss(restoreFocus: false) }
    @objc private func hostResigned() { dismiss() }

    override func layout() {
        super.layout()
        let width = min(500, max(0, bounds.width - 32))
        let desiredHeight = filteredCommands.isEmpty ? 130 : 80 + CGFloat(min(8, filteredCommands.count)) * 42
        let height = min(desiredHeight, max(0, bounds.height - 32))
        let top = min(max(16, bounds.height * 0.12), max(16, bounds.height - height - 16))
        card.frame = NSRect(x: (bounds.width - width) / 2, y: bounds.height - top - height, width: width, height: height)
        searchIcon.frame = NSRect(x: 16, y: height - 34, width: 18, height: 22)
        search.frame = NSRect(x: 44, y: height - 37, width: max(0, width - 88), height: SearchInputField.preferredHeight)
        clearButton.frame = NSRect(x: max(0, width - 36), y: height - 34, width: 20, height: 22)
        scroll.frame = NSRect(x: 6, y: 28, width: max(0, width - 12), height: max(0, height - 80))
        countLabel.frame = NSRect(x: 12, y: 7, width: max(0, width - 24), height: 14)
        table.frame.size.width = max(0, scroll.contentSize.width)
        table.sizeLastColumnToFit()
        empty.frame = NSRect(x: 12, y: max(6, height / 2 - 12), width: max(0, width - 24), height: 24)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }

    @objc private func clearQuery() {
        setQuery("")
        window?.makeFirstResponder(search)
    }

    func setQuery(_ query: String) {
        search.stringValue = query
        refilter()
    }
    private func refilter() {
        filteredCommands = CommandPaletteSearch.matchingIndices(in: commands, query: search.stringValue).map { commands[$0] }
        table.reloadData()
        clearButton.isHidden = search.stringValue.isEmpty
        empty.isHidden = !filteredCommands.isEmpty
        updateCount()
        if !filteredCommands.isEmpty { selectResult(at: 0) }
        needsLayout = true
    }
    private func updateCount() {
        countLabel.stringValue = catalog.text("%1$@ of %2$@ commands", arguments: [L10n.argument(filteredCommands.count), L10n.argument(commands.count)])
    }
    func selectResult(at index: Int) {
        guard filteredCommands.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }
    @objc func activateSelectedResult() {
        guard filteredCommands.indices.contains(table.selectedRow) else { return }
        let command = filteredCommands[table.selectedRow]
        guard let target = command.target,
              withInvocationContext({ CommandPaletteRegistry.isCurrentlyEnabled(command) }) else { NSSound.beep(); return }
        dismiss()
        onExecute?(command.item, target)
    }
    func controlTextDidChange(_ obj: Notification) { refilter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)): activateSelectedResult()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }
    private func moveSelection(_ offset: Int) {
        guard !filteredCommands.isEmpty else { return }
        selectResult(at: min(max(0, max(0, table.selectedRow) + offset), filteredCommands.count - 1))
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filteredCommands.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CommandPaletteRowView()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = filteredCommands[row]
        let identifier = NSUserInterfaceItemIdentifier("duckpad.command.cell")
        let cell = (table.makeView(withIdentifier: identifier, owner: self) as? CommandPaletteCell) ?? CommandPaletteCell()
        cell.identifier = identifier
        let enabled = withInvocationContext { CommandPaletteRegistry.isCurrentlyEnabled(command) }
        cell.apply(command, enabled: enabled, catalog: catalog)
        return cell
    }
}
