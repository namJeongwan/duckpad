import AppKit
import DuckpadApplication
import DuckpadLocalization

@MainActor
final class DeclarationCandidatePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSPopoverDelegate {
    struct Row { let name: String; let detail: String; var preview: String = "" }
    var onChoose: ((Int) -> Void)?
    private let popover = NSPopover()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [Row] = [], filtered: [Int] = []
    var isShown: Bool { popover.isShown }

    override init() {
        super.init()
        let controller = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 330))
        controller.view = root; popover.contentViewController = controller; popover.behavior = .transient; popover.delegate = self
        let column = NSTableColumn(identifier: .init("declaration"))
        column.resizingMask = .autoresizingMask; column.width = 520
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.rowHeight = 62; table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(choose)
        table.setAccessibilityIdentifier("duckpad.declarations.results")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityIdentifier("duckpad.declarations.search")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        for view in [search, scroll, status] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10), search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10), search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10), status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10), status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
    }
    func present(rows: [Row], complete: Bool, anchor: NSView, kind: SymbolNavigationKind = .declarations) {
        guard anchor.window != nil else { return }
        self.rows = rows; search.stringValue = ""
        let references = kind == .references
        search.placeholderString = L10n.text(references ? "Search reference candidates" : "Search declaration candidates")
        search.setAccessibilityLabel(search.placeholderString ?? "")
        table.setAccessibilityLabel(L10n.text(references ? "Reference candidates" : "Declaration candidates"))
        status.stringValue = references
            ? L10n.text(complete ? "Name matches only. Choose a reference candidate." : "Name matches only. Some files could not be searched.")
            : L10n.text(complete ? "Choose a declaration candidate" : "Some files could not be searched. Showing available candidates.")
        status.toolTip = status.stringValue
        refilter(); popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(search)
    }
    func showMessage(_ message: String) { status.stringValue = message; status.toolTip = message }
    func popoverDidClose(_ notification: Notification) { rows = []; filtered = []; onChoose = nil }
    func dismiss() { popover.close(); rows = []; filtered = []; onChoose = nil }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let value = rows[filtered[row]]
        let name = NSTextField(labelWithString: value.name)
        let detail = NSTextField(labelWithString: value.detail)
        let preview = NSTextField(labelWithString: value.preview)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let stack = NSStackView(views: [name, detail, preview])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        for label in [name, detail, preview] {
            label.lineBreakMode = label === detail ? .byTruncatingMiddle : .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let cell = NSTableCellView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.toolTip = "\(value.detail)\n\(value.preview)"
        return cell
    }
    func controlTextDidChange(_ obj: Notification) { refilter() }
    private func refilter() {
        let query = search.stringValue
        filtered = rows.indices.filter { query.isEmpty || "\(rows[$0].name) \(rows[$0].detail) \(rows[$0].preview)".localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    @objc private func choose() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        let selected = filtered[table.selectedRow], action = onChoose
        dismiss(); action?(selected)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.insertNewline(_:)) { choose(); return true }
        if command == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
        if command == #selector(NSResponder.moveDown(_:)) || command == #selector(NSResponder.moveUp(_:)) {
            guard !filtered.isEmpty else { return true }
            let next = min(max(0, table.selectedRow + (command == #selector(NSResponder.moveDown(_:)) ? 1 : -1)), filtered.count - 1)
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); table.scrollRowToVisible(next); return true
        }
        return false
    }
}
