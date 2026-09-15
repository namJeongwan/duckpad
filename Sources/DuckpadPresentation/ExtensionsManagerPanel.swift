import DuckpadLocalization
import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
final class ExtensionsManagerPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let installButton = NSButton(title: L10n.text("Install Plugin…"), target: nil, action: nil)
    private let updateButton = NSButton(title: L10n.text("Update"), target: nil, action: nil)
    private let checkButton = NSButton(title: L10n.text("Check for Plugin Updates"), target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private var buttonBar: WrappingButtonBar?
    private var updates: [ExtensionID: ExtensionUpdate] = [:]
    private var checking = false
    private var installing = false
    private var updateStatusKey = ""
    var onCheckUpdates: (() -> Void)?
    var onUpdate: ((ExtensionRegistryItem, ExtensionUpdate) -> Void)?
    var onInstall: ((URL) -> Void)?
    private let enableButton = NSButton(title: L10n.text("Enable"), target: nil, action: nil)
    private let revokeButton = NSButton(title: L10n.text("Revoke"), target: nil, action: nil)
    private var items: [ExtensionRegistryItem] = []
    var onSetEnabled: ((ExtensionID, Bool) -> Void)?
    var onRevoke: ((ExtensionRegistryItem) -> Void)?

    private var catalog = L10n.catalog

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        catalog.text(key, arguments: arguments)
    }

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = L10n.text("Duckpad Extensions")
        panel.minSize = NSSize(width: 500, height: 420)
        super.init(window: panel)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("extension")); column.title = localized("Extension")
        table.rowHeight = 24; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.addTableColumn(column); table.headerView = nil; table.delegate = self; table.dataSource = self
        table.setAccessibilityIdentifier("duckpad.extensions.list")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        let buttons = WrappingButtonBar(buttons: [installButton, updateButton, checkButton, enableButton, revokeButton])
        buttonBar = buttons
        updateButton.target = self; updateButton.action = #selector(updatePlugin)
        checkButton.target = self; checkButton.action = #selector(checkUpdates)
        updateButton.setAccessibilityIdentifier("duckpad.extensions.update")
        checkButton.setAccessibilityIdentifier("duckpad.extensions.check-updates")
        updateStatus.setAccessibilityIdentifier("duckpad.extensions.update-status")
        updateStatus.font = .systemFont(ofSize: 11); updateStatus.textColor = .secondaryLabelColor
        installButton.target = self; installButton.action = #selector(installPlugin)
        enableButton.target = self; enableButton.action = #selector(toggleEnabled)
        revokeButton.target = self; revokeButton.action = #selector(revoke)
        enableButton.setAccessibilityIdentifier("duckpad.extensions.enable")
        revokeButton.setAccessibilityIdentifier("duckpad.extensions.revoke")
        let stack = NSStackView(views: [scroll, updateStatus, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.contentView = stack
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        scroll.widthAnchor.constraint(equalTo: buttons.widthAnchor).isActive = true
        updateStatus.widthAnchor.constraint(equalTo: buttons.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        window?.title = localized("Duckpad Extensions")
        table.tableColumns.first?.title = localized("Extension")
        installButton.title = localized("Install Plugin…")
        checkButton.title = localized("Check for Plugin Updates")
        updateStatus.stringValue = updateStatusKey.isEmpty ? "" : localized(updateStatusKey)
        let selection = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selection, byExtendingSelection: false)
        updateButtons()
    }

    func renderUpdates(_ updates: [ExtensionID: ExtensionUpdate], checking: Bool, installing: Bool, statusKey: String) {
        self.updates = updates; self.checking = checking; self.installing = installing; updateStatusKey = statusKey
        updateStatus.stringValue = statusKey.isEmpty ? "" : localized(statusKey)
        updateButtons()
    }

    func render(_ state: ExtensionRegistryState) {
        let selectedID = selected?.manifest.id
        items = state.items
        table.reloadData()
        if let index = items.firstIndex(where: { $0.manifest.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !items.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateButtons()
    }

    func show(relativeTo window: NSWindow?) {
        showWindow(nil); self.window?.center(); self.window?.makeKeyAndOrderFront(nil)
        if let window, let panel = self.window { panel.setFrameOrigin(NSPoint(x: window.frame.midX - panel.frame.width / 2, y: window.frame.midY - panel.frame.height / 2)) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let identifier = NSUserInterfaceItemIdentifier("extension-item")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SingleLineTableCell) ?? SingleLineTableCell()
        cell.identifier = identifier
        let name = localized(item.manifest.name)
        cell.textField?.stringValue = "\(name)  \(item.manifest.version)  ·  \(item.enabled ? localized("Enabled") : localized("Disabled"))"
        if let pending = item.pendingVersion {
            cell.textField?.stringValue = localized("%1$@ %2$@ · %3$@ · %4$@ applies next launch", L10n.argument(name), L10n.argument(item.manifest.version), L10n.argument(item.enabled ? localized("Enabled") : localized("Disabled")), L10n.argument(pending))
        }
        cell.toolTip = localized("Publisher %1$@ · fingerprint %2$@ · package %3$@", L10n.argument(item.manifest.publisher.id), L10n.argument(item.publisherFingerprint), L10n.argument(item.packageDigest))
        cell.setAccessibilityLabel(localized("%1$@, version %2$@, publisher %3$@, fingerprint %4$@, %5$@, %6$@ exact capability scopes granted", L10n.argument(name), L10n.argument(item.manifest.version), L10n.argument(item.manifest.publisher.id), L10n.argument(item.publisherFingerprint), L10n.argument(item.enabled ? localized("Enabled") : localized("Disabled")), L10n.argument(item.granted.count)))
        if item.pendingVersion != nil {
            cell.toolTip = [cell.textField?.stringValue, cell.toolTip].compactMap { $0 }.joined(separator: "\n")
            cell.setAccessibilityLabel(cell.toolTip)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc private func installPlugin() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.treatsFilePackagesAsDirectories = true; picker.allowsMultipleSelection = false
        picker.message = localized("Choose a signed .duckpad-plugin package.")
        if picker.runModal() == .OK, let url = picker.url { onInstall?(url) }
    }

    @objc private func toggleEnabled() {
        guard let item = selected else { return }
        onSetEnabled?(item.manifest.id, !item.enabled)
    }
    @objc private func updatePlugin() { if let selected, let update = updates[selected.manifest.id], !installing { onUpdate?(selected, update) } }
    @objc private func checkUpdates() { onCheckUpdates?() }

    @objc private func revoke() { if let selected { onRevoke?(selected) } }

    private var selected: ExtensionRegistryItem? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }
    private func updateButtons() {
        let update = selected.flatMap { updates[$0.manifest.id] }
        updateButton.isEnabled = update != nil && !installing
        updateButton.title = installing ? localized("Installing Plugin…") : update.map { localized("Update to %1$@", L10n.argument($0.version)) } ?? localized("Update")
        checkButton.isEnabled = !checking && !installing
        installButton.isEnabled = !installing
        enableButton.isEnabled = selected != nil; enableButton.title = selected?.enabled == true ? localized("Disable") : localized("Enable")
        revokeButton.isEnabled = selected?.issue != nil || (selected?.enabled == true && !(selected?.granted.isEmpty ?? true))
        revokeButton.title = selected?.issue == .untrustedPublisher ? localized("Reset Publisher Revocation…") : localized("Revoke Publisher…")
        buttonBar?.refresh()
    }
}
