import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
final class ExtensionsManagerPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let enableButton = NSButton(title: "Enable", target: nil, action: nil)
    private let grantButton = NSButton(title: "Grant Requested Capabilities", target: nil, action: nil)
    private let revokeButton = NSButton(title: "Revoke", target: nil, action: nil)
    private var items: [ExtensionRegistryItem] = []
    var onSetEnabled: ((ExtensionID, Bool) -> Void)?
    var onGrantRequested: ((ExtensionRegistryItem) -> Void)?
    var onRevoke: ((ExtensionRegistryItem) -> Void)?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Duckpad Extensions"
        super.init(window: panel)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("extension")); column.title = "Extension"
        table.addTableColumn(column); table.headerView = nil; table.delegate = self; table.dataSource = self
        table.setAccessibilityIdentifier("duckpad.extensions.list")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        let buttons = NSStackView(views: [enableButton, grantButton, revokeButton]); buttons.orientation = .horizontal; buttons.spacing = 8
        enableButton.target = self; enableButton.action = #selector(toggleEnabled)
        grantButton.target = self; grantButton.action = #selector(grantRequested)
        revokeButton.target = self; revokeButton.action = #selector(revoke)
        enableButton.setAccessibilityIdentifier("duckpad.extensions.enable")
        grantButton.setAccessibilityIdentifier("duckpad.extensions.grant")
        revokeButton.setAccessibilityIdentifier("duckpad.extensions.revoke")
        let stack = NSStackView(views: [scroll, buttons]); stack.orientation = .vertical; stack.spacing = 8; stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.contentView = stack
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func render(_ state: ExtensionRegistryState) {
        items = state.items
        table.reloadData()
        if table.selectedRow < 0, !items.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateButtons()
    }

    func show(relativeTo window: NSWindow?) {
        showWindow(nil); self.window?.center(); self.window?.makeKeyAndOrderFront(nil)
        if let window { self.window?.setFrameOrigin(NSPoint(x: window.frame.midX - 310, y: window.frame.midY - 170)) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let field = NSTextField(labelWithString: "\(item.manifest.name)  \(item.manifest.version)  ·  \(item.enabled ? "Enabled" : "Disabled")")
        field.toolTip = "Publisher \(item.manifest.publisher.id) · fingerprint \(item.publisherFingerprint) · package \(item.packageDigest)"
        field.setAccessibilityLabel("\(item.manifest.name), version \(item.manifest.version), publisher \(item.manifest.publisher.id), fingerprint \(item.publisherFingerprint), \(item.enabled ? "enabled" : "disabled"), \(item.granted.count) exact capability scopes granted")
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc private func toggleEnabled() {
        guard let item = selected else { return }
        onSetEnabled?(item.manifest.id, !item.enabled)
    }

    @objc private func grantRequested() { if let selected { onGrantRequested?(selected) } }
    @objc private func revoke() { if let selected { onRevoke?(selected) } }

    private var selected: ExtensionRegistryItem? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }
    private func updateButtons() {
        enableButton.isEnabled = selected != nil; enableButton.title = selected?.enabled == true ? "Disable" : "Enable"
        grantButton.isEnabled = selected?.enabled == true && selected?.issue == nil
        revokeButton.isEnabled = selected?.issue != nil || (selected?.enabled == true && !(selected?.granted.isEmpty ?? true))
        revokeButton.title = selected?.issue == .untrustedPublisher ? "Reset Publisher Revocation…" : "Revoke Publisher…"
    }
}
