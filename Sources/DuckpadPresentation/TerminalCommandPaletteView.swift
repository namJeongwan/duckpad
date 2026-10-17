import AppKit
import DuckpadLocalization

/// An in-window overlay: never opens a popover outside the editor's bounds.
@MainActor
final class TerminalCommandPaletteView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onExecute: ((NSMenuItem, AnyObject) -> Void)?
    private let card = NSVisualEffectView()
    private let search = NSTextField()
    private let searchIcon = NSImageView()
    private let clearButton = NSButton()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private var commands: [CommandPaletteCommand] = []
    private(set) var filteredCommands: [CommandPaletteCommand] = []
    private weak var returnFocus: NSResponder?
    private var keyMonitor: Any?
    var isPresented: Bool { superview != nil }
    var cardFrame: NSRect { card.frame }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        setAccessibilityIdentifier("duckpad.terminal.commands")
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
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        card.appearance = NSAppearance(named: .darkAqua)
        addSubview(card)
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 14)
        search.isBezeled = false
        search.isEditable = true
        search.isSelectable = true
        search.cell?.usesSingleLineMode = true
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
        search.setAccessibilityIdentifier("duckpad.terminal.commands.search")
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
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .fullWidth
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateSelectedResult)
        table.setAccessibilityIdentifier("duckpad.terminal.commands.results")
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
    }

    required init?(coder: NSCoder) { nil }

    func present(menu: NSMenu, in host: NSView, catalog: LocalizationCatalog = L10n.catalog) {
        dismiss()
        guard let window = host.window else { return }
        returnFocus = window.firstResponder
        commands = CommandPaletteRegistry.commands(in: menu)
        search.placeholderString = catalog.text("Search commands")
        clearButton.toolTip = catalog.text("Clear Search")
        clearButton.setAccessibilityLabel(catalog.text("Clear Search"))
        search.setAccessibilityLabel(catalog.text("Search Duckpad commands"))
        table.setAccessibilityLabel(catalog.text("Duckpad command search results"))
        empty.stringValue = catalog.text("No matching commands")
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
        if restoreFocus, let returnFocus { hostWindow?.makeFirstResponder(returnFocus) }
        returnFocus = nil
    }

    @objc private func hostClosed() { dismiss(restoreFocus: false) }
    @objc private func hostResigned() { dismiss() }

    override func layout() {
        super.layout()
        let width = min(500, max(0, bounds.width - 32))
        let desiredHeight = filteredCommands.isEmpty ? 130 : 58 + CGFloat(min(8, filteredCommands.count)) * 34
        let height = min(desiredHeight, max(0, bounds.height - 32))
        let top = min(max(16, bounds.height * 0.12), max(16, bounds.height - height - 16))
        card.frame = NSRect(x: (bounds.width - width) / 2, y: bounds.height - top - height, width: width, height: height)
        searchIcon.frame = NSRect(x: 16, y: height - 34, width: 18, height: 22)
        search.frame = NSRect(x: 44, y: height - 34, width: max(0, width - 88), height: 22)
        clearButton.frame = NSRect(x: max(0, width - 36), y: height - 34, width: 20, height: 22)
        scroll.frame = NSRect(x: 6, y: 6, width: max(0, width - 12), height: max(0, height - 58))
        table.tableColumns.first?.width = max(0, scroll.contentSize.width)
        empty.frame = NSRect(x: 12, y: max(6, height / 2 - 12), width: max(0, width - 24), height: 24)
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
        if !filteredCommands.isEmpty { selectResult(at: 0) }
        needsLayout = true
    }
    func selectResult(at index: Int) {
        guard filteredCommands.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }
    @objc func activateSelectedResult() {
        guard filteredCommands.indices.contains(table.selectedRow) else { return }
        let command = filteredCommands[table.selectedRow]
        guard let target = command.target, CommandPaletteRegistry.isCurrentlyEnabled(command) else { NSSound.beep(); return }
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
        selectResult(at: (max(0, table.selectedRow) + offset + filteredCommands.count) % filteredCommands.count)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filteredCommands.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TerminalCommandPaletteRowView()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = filteredCommands[row]
        let cell = TerminalCommandPaletteCell()
        cell.apply(command)
        return cell
    }
}
