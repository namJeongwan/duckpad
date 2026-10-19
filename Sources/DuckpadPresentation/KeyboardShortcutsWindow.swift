import AppKit
import DuckpadLocalization

@MainActor
final class KeyboardShortcutsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let table = ShortcutTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var buttons: [NSButton] = []
    private var registry: ShortcutRegistry?
    private var rows: [ShortcutRegistry.Entry] = []
    private(set) var capture: ShortcutChangePreview?
    private var editingID: String?
    private var saving = false
    var onSave: (([String: String], [String: String]) async -> Bool)?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 600, height: 380)
        super.init(window: panel)
        panel.delegate = self
        let content = NSView()
        panel.contentView = content
        search.delegate = self
        for (id, width) in [("Command", CGFloat(450)), ("Shortcut", CGFloat(220))] {
            let column = NSTableColumn(identifier: .init(id)); column.title = L10n.text(id == "Command" ? "Command Name" : "Shortcut"); column.width = width
            column.minWidth = 200
            column.resizingMask = id == "Command" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self
        table.onShortcutKey = { [weak self] event in self?.handleShortcutKey(event) ?? false }
        table.onFocusLeft = { [weak self] in self?.capture?.cancel() }
        table.target = self
        table.doubleAction = #selector(recordClickedRow(_:))
        table.rowHeight = 42
        table.allowsEmptySelection = false
        table.setAccessibilityLabel(L10n.text("Keyboard Shortcuts"))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        let actions: [(String, Selector)] = [
            ("Edit Shortcut", #selector(record)), ("Remove Shortcut", #selector(remove)),
            ("Restore Default", #selector(restore)), ("Restore All Defaults", #selector(restoreAll))
        ]
        buttons = actions.map { NSButton(title: L10n.text($0.0), target: self, action: $0.1) }
        let firstRow = NSStackView(views: Array(buttons.prefix(2)))
        let secondRow = NSStackView(views: Array(buttons.suffix(2)))
        for row in [firstRow, secondRow] { row.distribution = .fillEqually; row.spacing = 8 }
        let bar = NSStackView(views: [firstRow, secondRow]); bar.orientation = .vertical; bar.spacing = 8
        firstRow.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        secondRow.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        status.textColor = .secondaryLabelColor
        for view in [search, scroll, bar, status] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12), bar.leadingAnchor.constraint(equalTo: search.leadingAnchor), bar.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            status.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10), status.leadingAnchor.constraint(equalTo: search.leadingAnchor), status.trailingAnchor.constraint(equalTo: search.trailingAnchor), status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(registry: ShortcutRegistry) {
        refresh(registry: registry)
        window?.title = L10n.text("Keyboard Shortcuts")
        search.placeholderString = L10n.text("Search commands")
        status.stringValue = L10n.text("Select a command and press a shortcut, or double-click. Enter applies · Esc cancels.")
        window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }

    func refresh(registry: ShortcutRegistry) {
        self.registry = registry
        window?.title = L10n.text("Keyboard Shortcuts")
        search.placeholderString = L10n.text("Search commands")
        table.setAccessibilityLabel(L10n.text("Keyboard Shortcuts"))
        table.tableColumns.first?.title = L10n.text("Command Name")
        table.tableColumns.last?.title = L10n.text("Shortcut")
        for (button, key) in zip(buttons, ["Edit Shortcut", "Remove Shortcut", "Restore Default", "Restore All Defaults"]) {
            button.title = L10n.text(key)
        }
        status.stringValue = L10n.text("Select a command and press a shortcut, or double-click. Enter applies · Esc cancels.")
        capture?.cancel()
        reload()
    }

    private var selected: ShortcutRegistry.Entry? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func reload() {
        let id = selected?.id
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = registry?.entries.filter { query.isEmpty || ($0.title + " " + $0.path + " " + $0.id).localizedCaseInsensitiveContains(query) } ?? []
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: rows.firstIndex { $0.id == id } ?? 0), byExtendingSelection: false) }
        updateButtons()
    }
    private func updateButtons() {
        for (index, button) in buttons.enumerated() { button.isEnabled = !saving && (index == 3 || selected != nil) }
        search.isEnabled = !saving
        table.isEnabled = !saving
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if editingID != selected?.id { capture?.cancel() }
        updateButtons()
    }
    func controlTextDidChange(_ obj: Notification) { capture?.cancel(); reload() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        let isShortcut = tableColumn?.identifier.rawValue == "Shortcut"
        if entry.id == editingID, isShortcut, let capture { return capture }
        let cell = ShortcutTableCell()
        cell.configure(title: isShortcut ? entry.displayShortcut : entry.title,
                       detail: isShortcut ? nil : entry.path)
        cell.toolTip = isShortcut ? L10n.text("Double-click to edit shortcut") : entry.title + " — " + entry.path
        return cell
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        42
    }


    @objc private func recordClickedRow(_ sender: NSTableView) {
        guard !saving, rows.indices.contains(sender.clickedRow) else { return }
        table.selectRowIndexes(IndexSet(integer: sender.clickedRow), byExtendingSelection: false)
        record()
    }

    @objc private func record() {
        guard let selected, let registry, let window, !saving else { return }
        window.makeFirstResponder(table)
        if selected.id == editingID { return }
        capture?.cancel()
        let preview = ShortcutChangePreview(entry: selected, registry: registry)
        capture = preview; editingID = selected.id
        preview.onComplete = { [weak self] declaration in
            guard let self else { return }
            self.endEditing()
            if let declaration { self.change(id: selected.id, declaration: declaration) }
        }
        preview.onFeedback = { [weak self, weak preview] in
            guard let self, let preview else { return }
            self.status.stringValue = preview.feedback
            self.status.textColor = preview.hasError ? .systemRed : .secondaryLabelColor
        }
        status.stringValue = preview.feedback
        status.textColor = .secondaryLabelColor
        let row = table.selectedRow
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 1))
        table.scrollRowToVisible(row)
    }

    func handleShortcutKey(_ event: NSEvent) -> Bool {
        guard !saving, selected != nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Normal navigation stays available; moving away cancels the draft.
        if flags.isEmpty && [48, 123, 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode) {
            capture?.cancel()
            return false
        }
        if event.keyCode == 48 && flags == [.shift] { capture?.cancel(); return false }
        if event.keyCode == 53 && flags.isEmpty {
            capture?.cancel()
            return true
        }
        if event.isARepeat { return true }
        if capture == nil {
            record()
            if event.keyCode == 36 && flags.isEmpty { return true }
        }
        capture?.capture(event)
        return true
    }

    private func endEditing() {
        let row = rows.firstIndex { $0.id == editingID }
        capture?.onComplete = nil; capture?.onFeedback = nil
        capture = nil; editingID = nil
        status.stringValue = L10n.text("Select a command and press a shortcut, or double-click. Enter applies · Esc cancels.")
        status.textColor = .secondaryLabelColor
        if let row {
            table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 1))
        }
    }

    @objc private func remove() { if let selected { change(id: selected.id, declaration: "") } }
    @objc private func restore() {
        guard let selected, let registry else { return }
        if let conflict = registry.entries.first(where: { $0.id != selected.id && !$0.identities.isDisjoint(with: selected.defaultIdentities) }) {
            status.stringValue = L10n.text("Shortcut already used by %1$@", L10n.argument(conflict.title)); return
        }
        change(id: selected.id, declaration: nil)
    }
    @objc private func restoreAll() { save([:]) }
    private func change(id: String, declaration: String?) {
        var bindings = registry?.overrides ?? [:]; bindings[id] = declaration; save(bindings)
    }
    private func save(_ bindings: [String: String]) {
        guard !saving, let registry, let onSave else { return }
        capture?.cancel()
        saving = true; updateButtons()
        Task { [weak self] in
            let saved = await onSave(bindings, registry.overrides)
            guard let self else { return }
            self.saving = false; self.updateButtons()
            // Disabling the table during persistence can move first responder away.
            // Keep the selected row ready for the next shortcut without another click.
            self.window?.makeFirstResponder(self.table)
            self.status.stringValue = L10n.text(saved ? "Shortcut settings saved" : "Could not save shortcut settings. Please try again.")
        }
    }
    func windowDidResignKey(_ notification: Notification) { capture?.cancel() }
    func windowWillClose(_ notification: Notification) { capture?.cancel() }
}
