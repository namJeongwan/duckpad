import DuckpadLocalization
import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
private final class WorkspaceOutlineView: NSOutlineView {
    var onPressReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onPressReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class WorkspaceSidebarNode: NSObject {
    enum Kind { case root, directory, file }

    let rootID: WorkspaceRootID
    let relativePath: String
    let name: String
    let kind: Kind
    let isAvailable: Bool
    weak var parent: WorkspaceSidebarNode?
    var children: [WorkspaceSidebarNode]?
    var isLoading = false
    var failure: WorkspaceBrowserFailure?

    init(root: WorkspaceRoot) {
        rootID = root.id
        relativePath = ""
        name = root.displayName
        kind = .root
        isAvailable = root.isAvailable
        children = root.isAvailable ? nil : []
    }

    init(entry: WorkspaceBrowserEntry, parent: WorkspaceSidebarNode) {
        rootID = entry.rootID
        relativePath = entry.relativePath
        name = entry.name
        kind = entry.kind == .directory ? .directory : .file
        isAvailable = true
        self.parent = parent
        children = kind == .directory ? nil : []
    }

    var isExpandable: Bool { isAvailable && kind != .file }
}

@MainActor
final class WorkspaceSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onAddRoot: (() -> Void)?
    var onRemoveRoot: ((WorkspaceRootID) -> Void)?
    var onOpenFile: ((WorkspaceBrowserEntry) -> Void)?
    var onLoadChildren: ((WorkspaceRootID, String) -> Void)?
    var onNavigationChange: ((WorkspaceRootID, [String], String?) -> Void)?
    var onDropFolder: ((URL) -> Void)?
    var onRevealPath: ((String) -> Void)?

    private let header = NSVisualEffectView(frame: .zero)
    private let title = NSTextField(labelWithString: L10n.text("Workspace"))
    private let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.text("Add Folder"))!, target: nil, action: nil)
    private let removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: L10n.text("Remove Folder"))!, target: nil, action: nil)
    private let outline = WorkspaceOutlineView(frame: .zero)
    private let scroll = NSScrollView(frame: .zero)
    private let emptyLabel = NSTextField(wrappingLabelWithString: L10n.text("Add a folder to browse files here."))
    private var roots: [WorkspaceRoot] = []
    private var rootNodes: [WorkspaceSidebarNode] = []
    private var isRestoringNavigation = false
    private var interactionsEnabled = true
    private var contextNode: WorkspaceSidebarNode?
    private var displayedFailure: WorkspaceBrowserFailure?
    private var localizationCatalog = L10n.catalog

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("duckpad.workspace.sidebar")
        registerForDraggedTypes([.fileURL])

        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active
        header.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        for button in [addButton, removeButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(button)
        }
        addButton.target = self
        addButton.action = #selector(addPressed)
        removeButton.target = self
        removeButton.action = #selector(removePressed)
        removeButton.isEnabled = false
        header.addSubview(title)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace"))
        column.title = L10n.text("Workspace")
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 14
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelected)
        outline.onPressReturn = { [weak self] in self?.openSelected() }
        let contextMenu = NSMenu(title: L10n.text("Workspace"))
        contextMenu.delegate = self
        outline.menu = contextMenu
        outline.setAccessibilityLabel(L10n.text("Workspace files"))
        outline.setAccessibilityIdentifier("duckpad.workspace.outline")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(scroll)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 9),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -2),
            removeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @discardableResult
    func apply(roots: [WorkspaceRoot]) -> Bool {
        displayedFailure = nil
        let structureChanged = self.roots.count != roots.count || !zip(self.roots, roots).allSatisfy {
            $0.id == $1.id && $0.canonicalPath == $1.canonicalPath && $0.isAvailable == $1.isAvailable
        }
        self.roots = roots
        title.stringValue = L10n.text("Workspace")
        title.toolTip = nil
        emptyLabel.stringValue = L10n.text("Add a folder to browse files here.")
        emptyLabel.isHidden = !roots.isEmpty
        if structureChanged {
            rootNodes = roots.map(WorkspaceSidebarNode.init(root:))
            outline.reloadData()
        }
        updateRemoveButton()
        return structureChanged
    }

    func applyChildren(
        rootID: WorkspaceRootID,
        relativeDirectory: String,
        entries: [WorkspaceBrowserEntry]
    ) {
        guard let parent = node(rootID: rootID, relativePath: relativeDirectory) else { return }
        parent.isLoading = false
        parent.failure = nil
        parent.children = entries.map { WorkspaceSidebarNode(entry: $0, parent: parent) }
        outline.reloadItem(parent, reloadChildren: true)
    }

    func applyChildrenFailure(
        rootID: WorkspaceRootID,
        relativeDirectory: String,
        failure: WorkspaceBrowserFailure
    ) {
        guard let parent = node(rootID: rootID, relativePath: relativeDirectory) else { return }
        displayedFailure = failure
        parent.isLoading = false
        parent.failure = failure
        parent.children = nil
        title.stringValue = L10n.text("Workspace ⚠")
        title.toolTip = PresentationErrorText.message(failure)
        outline.reloadItem(parent, reloadChildren: true)
    }

    func setInteractionsEnabled(_ enabled: Bool) {
        interactionsEnabled = enabled
        outline.isEnabled = enabled
        addButton.isEnabled = enabled
        updateRemoveButton()
    }

    func presentFailure(_ failure: WorkspaceBrowserFailure) {
        displayedFailure = failure
        title.stringValue = L10n.text("Workspace ⚠")
        title.toolTip = PresentationErrorText.message(failure)
        if roots.isEmpty {
            emptyLabel.stringValue = L10n.text("Workspace unavailable\n%1$@", L10n.argument(PresentationErrorText.message(failure)))
            emptyLabel.isHidden = false
        }
    }

    var selectedRootID: WorkspaceRootID? { selectedNode?.rootID }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        localizationCatalog = catalog
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? WorkspaceSidebarNode,
                  let failure = node.failure,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            cell.toolTip = PresentationErrorText.message(failure, catalog: catalog)
        }
        setAccessibilityLabel(catalog.text("Workspace"))
        title.stringValue = catalog.text(displayedFailure == nil ? "Workspace" : "Workspace ⚠")
        addButton.setAccessibilityLabel(catalog.text("Add Folder"))
        addButton.toolTip = catalog.text("Add Folder")
        removeButton.setAccessibilityLabel(catalog.text("Remove Folder"))
        removeButton.toolTip = catalog.text("Remove Folder")
        outline.setAccessibilityLabel(catalog.text("Workspace files"))
        outline.tableColumns.first?.title = catalog.text("Workspace")
        outline.menu?.title = catalog.text("Workspace")
        if let displayedFailure {
            let detail = PresentationErrorText.message(displayedFailure, catalog: catalog)
            title.toolTip = detail
            if roots.isEmpty { emptyLabel.stringValue = catalog.text("Workspace unavailable\n%1$@", arguments: [detail]) }
        } else {
            emptyLabel.stringValue = catalog.text("Add a folder to browse files here.")
        }
    }

    func restoreNavigation(for root: WorkspaceRoot) {
        isRestoringNavigation = true
        defer { isRestoringNavigation = false }
        for path in root.expandedRelativePaths.sorted(by: Self.pathDepthOrder) {
            if let node = node(rootID: root.id, relativePath: path) { outline.expandItem(node) }
        }
        if let selected = root.selectedRelativePath,
           let node = node(rootID: root.id, relativePath: selected) {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
    }

    func revealLoadedNode(rootID: WorkspaceRootID, relativePath: String) {
        guard let node = node(rootID: rootID, relativePath: relativePath) else { return }
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? WorkspaceSidebarNode else { return rootNodes.count }
        return item.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? WorkspaceSidebarNode else { return rootNodes[index] }
        return item.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? WorkspaceSidebarNode)?.isExpandable == true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? WorkspaceSidebarNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("WorkspaceCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView(frame: .zero)
            cell.identifier = identifier
            let image = NSImageView(frame: .zero)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = image
            cell.textField = label
            cell.addSubview(image)
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 21),
                image.heightAnchor.constraint(equalToConstant: 21),
                label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = node.name
        cell.textField?.font = .systemFont(ofSize: 12, weight: node.kind == .root ? .semibold : .regular)
        cell.textField?.textColor = node.isAvailable ? .labelColor : .secondaryLabelColor
        let symbol: String
        if node.failure != nil {
            symbol = "exclamationmark.triangle"
        } else {
            switch node.kind {
            case .root: symbol = node.isAvailable ? "folder.fill" : "folder.badge.questionmark"
            case .directory: symbol = "folder"
            case .file: symbol = "doc.text"
            }
        }
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.toolTip = node.failure.map { PresentationErrorText.message($0, catalog: localizationCatalog) } ?? (node.kind == .root
            ? roots.first(where: { $0.id == node.rootID })?.canonicalPath
            : node.relativePath)
        cell.setAccessibilityLabel(node.name)
        return cell
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard interactionsEnabled, !isRestoringNavigation,
              let node = notification.userInfo?["NSObject"] as? WorkspaceSidebarNode,
              node.isExpandable, node.children == nil, !node.isLoading else { return }
        node.isLoading = true
        onLoadChildren?(node.rootID, node.relativePath)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? WorkspaceSidebarNode else { return }
        publishNavigation(rootID: node.rootID)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? WorkspaceSidebarNode else { return }
        publishNavigation(rootID: node.rootID)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
        if let rootID = selectedNode?.rootID { publishNavigation(rootID: rootID) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFolder(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard interactionsEnabled, let url = droppedFolder(from: sender) else { return false }
        onDropFolder?(url)
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        contextNode = row >= 0 ? outline.item(atRow: row) as? WorkspaceSidebarNode : selectedNode
        guard let contextNode else { return }
        let reveal = menu.addItem(withTitle: L10n.text("Reveal in Finder"), action: #selector(revealContextPath), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = contextNode.isAvailable
        menu.addItem(.separator())
        let remove = menu.addItem(
            withTitle: L10n.text("Remove Folder from Workspace"),
            action: #selector(removeContextRoot),
            keyEquivalent: ""
        )
        remove.target = self
        remove.isEnabled = interactionsEnabled
    }

    @objc private func addPressed() { if interactionsEnabled { onAddRoot?() } }

    @objc private func removePressed() {
        guard interactionsEnabled, let rootID = selectedNode?.rootID else { return }
        onRemoveRoot?(rootID)
    }

    @objc private func openSelected() {
        guard interactionsEnabled, let node = selectedNode else { return }
        switch node.kind {
        case .file:
            onOpenFile?(.init(rootID: node.rootID, relativePath: node.relativePath, name: node.name, kind: .file))
        case .root, .directory:
            if outline.isItemExpanded(node) { outline.collapseItem(node) }
            else { outline.expandItem(node) }
        }
    }

    @objc private func revealContextPath() {
        guard let node = contextNode,
              let root = roots.first(where: { $0.id == node.rootID }) else { return }
        let path = node.relativePath.isEmpty
            ? root.canonicalPath
            : URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
                .appendingPathComponent(node.relativePath).path
        onRevealPath?(path)
    }

    @objc private func removeContextRoot() {
        guard interactionsEnabled, let rootID = contextNode?.rootID else { return }
        onRemoveRoot?(rootID)
    }

    private var selectedNode: WorkspaceSidebarNode? {
        guard outline.selectedRow >= 0 else { return nil }
        return outline.item(atRow: outline.selectedRow) as? WorkspaceSidebarNode
    }

    private func updateRemoveButton() {
        removeButton.isEnabled = interactionsEnabled && selectedNode != nil
    }

    private func publishNavigation(rootID: WorkspaceRootID) {
        guard !isRestoringNavigation else { return }
        var expanded: [String] = []
        traverse(rootNodes.first(where: { $0.rootID == rootID })) { node in
            if node.isExpandable, outline.isItemExpanded(node) { expanded.append(node.relativePath) }
        }
        let selectedPath = selectedNode?.rootID == rootID ? selectedNode?.relativePath : nil
        onNavigationChange?(rootID, expanded, selectedPath)
    }

    private func traverse(_ node: WorkspaceSidebarNode?, visit: (WorkspaceSidebarNode) -> Void) {
        guard let node else { return }
        visit(node)
        node.children?.forEach { traverse($0, visit: visit) }
    }

    private func node(rootID: WorkspaceRootID, relativePath: String) -> WorkspaceSidebarNode? {
        guard let root = rootNodes.first(where: { $0.rootID == rootID }) else { return nil }
        if relativePath.isEmpty { return root }
        var result: WorkspaceSidebarNode?
        traverse(root) {
            if $0.relativePath == relativePath { result = $0 }
        }
        return result
    }

    private func droppedFolder(from sender: any NSDraggingInfo) -> URL? {
        guard let url = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.first else { return nil }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? url : nil
    }

    private static func pathDepthOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/").count
        let right = rhs.split(separator: "/").count
        return left == right ? lhs < rhs : left < right
    }
}
