import AppKit
import DuckpadDomain
import DuckpadLocalization

/// Catalog discovery uses its own selection so switching lists preserves context.
@MainActor
final class ExtensionCatalogView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let search = NSSearchField()
    private let table = NSTableView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let install = NSButton(title: "", target: nil, action: nil)
    private var buttonBar: WrappingButtonBar?
    private let retry = NSButton(title: "", target: nil, action: nil)
    private var plugins: [ExtensionCatalogPlugin] = []
    private var visible: [ExtensionCatalogPlugin] = []
    private var installed: Set<ExtensionID> = []
    private var loading = false
    private var busy = false
    private var statusKey = ""
    private var catalog = L10n.catalog
    var onReload: (() -> Void)?
    var onInstall: ((ExtensionCatalogPlugin) -> Void)?

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("catalog"))
        table.addTableColumn(column); table.headerView = nil
        table.rowHeight = 24; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.delegate = self; table.dataSource = self
        table.setAccessibilityIdentifier("duckpad.extensions.catalog.list")
        search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityIdentifier("duckpad.extensions.catalog.search")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        install.target = self; install.action = #selector(installSelected)
        install.setAccessibilityIdentifier("duckpad.extensions.catalog.install")
        retry.target = self; retry.action = #selector(reloadCatalog)
        retry.setAccessibilityIdentifier("duckpad.extensions.catalog.refresh")
        detail.maximumNumberOfLines = 4; detail.font = .systemFont(ofSize: 12)
        detail.setAccessibilityIdentifier("duckpad.extensions.catalog.description")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("duckpad.extensions.catalog.status")
        let buttons = WrappingButtonBar(buttons: [install, retry])
        buttonBar = buttons
        let stack = NSStackView(views: [search, scroll, detail, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        for view in [search, scroll, detail, status, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        refreshLocalization(catalog: catalog)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func refreshLocalization(catalog: LocalizationCatalog) {
        self.catalog = catalog
        search.placeholderString = catalog.text("Search Plugins")
        search.setAccessibilityLabel(catalog.text("Search Plugins"))
        retry.title = catalog.text("Refresh Catalog")
        filter()
    }
    func render(_ plugins: [ExtensionCatalogPlugin], installed: Set<ExtensionID>, loading: Bool, busy: Bool, statusKey: String) {
        self.plugins = plugins; self.installed = installed; self.loading = loading; self.busy = busy; self.statusKey = statusKey
        filter()
    }
    func controlTextDidChange(_ notification: Notification) { filter() }
    private func filter() {
        let id = selected?.release.extensionID
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = plugins.filter {
            query.isEmpty || [$0.name, $0.release.extensionID.rawValue, $0.description(language: catalog.language.rawValue)]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        table.reloadData()
        if let row = visible.firstIndex(where: { $0.release.extensionID == id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !visible.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        status.stringValue = catalog.text(!statusKey.isEmpty ? statusKey : visible.isEmpty ? (query.isEmpty ? "No Compatible Plugins Available" : "No Matching Plugins") : "")
        updateSelection()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visible.indices.contains(row) else { return nil }
        let item = visible[row]
        let id = NSUserInterfaceItemIdentifier("catalog-plugin")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SingleLineTableCell) ?? SingleLineTableCell()
        cell.identifier = id
        let state = catalog.text(installed.contains(item.release.extensionID) ? "Installed" : "Available")
        cell.textField?.stringValue = "\(item.name)  \(item.release.version)  ·  \(state)"
        cell.setAccessibilityLabel(cell.textField?.stringValue)
        cell.toolTip = item.description(language: catalog.language.rawValue)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private var selected: ExtensionCatalogPlugin? { visible.indices.contains(table.selectedRow) ? visible[table.selectedRow] : nil }
    private func updateSelection() {
        let alreadyInstalled = selected.map { installed.contains($0.release.extensionID) } ?? false
        detail.stringValue = selected?.description(language: catalog.language.rawValue) ?? ""
        install.title = catalog.text(busy ? "Installing Plugin…" : alreadyInstalled ? "Installed" : "Install")
        install.isEnabled = selected != nil && !alreadyInstalled && !busy && !loading
        retry.isEnabled = !loading && !busy
        buttonBar?.refresh()
    }
    @objc private func installSelected() { if install.isEnabled, let selected { onInstall?(selected) } }
    @objc private func reloadCatalog() { onReload?() }
}
