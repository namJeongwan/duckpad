import AppKit
import DuckpadLocalization
import DuckpadApplication

@MainActor
final class FileNameSearchController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onOpen: ((FileNameSearchEntry) -> Void)?
    var onOpenInSplit: ((FileNameSearchEntry) -> Void)?
    var onLoad: (() async throws -> (entries: [FileNameSearchEntry], truncated: Bool, skipped: Int))?
    private let query = SearchInputField()
    private let table = SearchResultTableView()
    private let status = NSTextField(labelWithString: "")
    private let selectedPath = NSTextField(labelWithString: "")
    var onLoadRequest: ((ProjectSearchScope, URL?) async throws -> (entries: [FileNameSearchEntry], truncated: Bool, skipped: Int))?
    var onChooseFolder: (() async -> URL?)?
    private let scope = NSStackView()
    private let scopeTabs = ProjectSearchScope.allCases.map { _ in SearchOptionButton() }
    private let directory = NSTextField(labelWithString: "")
    private let browse = StatusBarButton()
    private var workspacePaths: [String] = []
    private var initialEntries: [FileNameSearchEntry] = []
    private(set) var folder: URL?
    private(set) var selectedScope: ProjectSearchScope = .all
    private let clear = StatusBarButton()
    private let splitButton = StatusBarButton()
    private let empty = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let dismissal = SearchPopupDismissal()
    private var task: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var filterGeneration = UUID()
    private var generation = UUID()
    private var entries: [FileNameSearchEntry] = []
    private(set) var results: [FileNameSearchEntry] = []
    private var catalog = L10n.catalog
    private var loading = false, truncated = false
    private var skipped = 0
    private weak var returnFocus: NSResponder?

    init() {
        let panel = SearchPopupPanel(size: .init(width: 760, height: 540), identifier: "duckpad.files.window")
        panel.minSize = .init(width: 520, height: 320)
        super.init(window: panel)
        panel.delegate = self
        let root = SearchSurfaceView(.panel)
        scope.orientation = .horizontal; scope.alignment = .centerY; scope.spacing = 16
        scope.setAccessibilityIdentifier("duckpad.files.scope")
        for (value, tab) in zip(ProjectSearchScope.allCases, scopeTabs) {
            tab.font = .systemFont(ofSize: 13)
            tab.setAccessibilityIdentifier("duckpad.files.scope.\(value.rawValue)")
            tab.setAccessibilityRole(.radioButton)
            tab.onToggle = { [weak self] _ in self?.selectScope(value) }
            scope.addArrangedSubview(tab)
        }
        let header = NSStackView(views: [scope, NSView()]); header.orientation = .horizontal; header.spacing = 16
        header.alignment = .centerY; header.heightAnchor.constraint(equalToConstant: 42).isActive = true
        directory.font = .systemFont(ofSize: 11); directory.textColor = .secondaryLabelColor
        directory.lineBreakMode = .byTruncatingMiddle
        directory.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        directory.setAccessibilityIdentifier("duckpad.files.directory")
        browse.font = .systemFont(ofSize: 11); browse.isBordered = false
        browse.target = self; browse.action = #selector(browsePressed)
        browse.setAccessibilityIdentifier("duckpad.files.browse")
        browse.setContentCompressionResistancePriority(.required, for: .horizontal)
        let context = NSStackView(views: [directory, browse, NSView(), status])
        context.orientation = .horizontal; context.alignment = .centerY; context.spacing = 12
        context.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true; icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        query.delegate = self; query.setAccessibilityIdentifier("duckpad.files.query")
        query.heightAnchor.constraint(equalToConstant: SearchInputField.preferredHeight).isActive = true
        clear.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil); clear.isBordered = false; clear.imagePosition = .imageOnly
        clear.target = self; clear.action = #selector(clearQuery)
        clear.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let input = NSStackView(views: [icon, query, clear]); input.orientation = .horizontal; input.spacing = 12; input.alignment = .centerY
        input.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let divider = NSBox(); divider.boxType = .separator
        let headerDivider = NSBox(); headerDivider.boxType = .separator
        let footerDivider = NSBox(); footerDivider.boxType = .separator
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        table.headerView = nil; table.rowHeight = 28; table.intercellSpacing = .init(width: 0, height: 1)
        table.style = .plain; table.backgroundColor = .clear
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(activateSelection)
        table.onActivate = { [weak self] in self?.activateSelection() }; table.onDismiss = { [weak self] in self?.dismiss() }
        table.setAccessibilityIdentifier("duckpad.files.results")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectedPath.font = .systemFont(ofSize: 12); selectedPath.textColor = .secondaryLabelColor; selectedPath.lineBreakMode = .byTruncatingMiddle
        selectedPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectedPath.setAccessibilityIdentifier("duckpad.files.path")
        splitButton.isBordered = false; splitButton.font = .systemFont(ofSize: 12); splitButton.contentTintColor = .controlAccentColor
        splitButton.target = self; splitButton.action = #selector(activateInSplit)
        splitButton.setAccessibilityIdentifier("duckpad.files.split")
        splitButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        splitButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSStackView(views: [selectedPath, NSView(), splitButton]); footer.orientation = .horizontal; footer.spacing = 12; footer.alignment = .centerY
        footer.heightAnchor.constraint(equalToConstant: 40).isActive = true
        empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor
        for view in [header, headerDivider, input, divider, context, scroll, footerDivider, footer, empty] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), header.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor), headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor), headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            input.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), input.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), input.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor), divider.trailingAnchor.constraint(equalTo: root.trailingAnchor), divider.topAnchor.constraint(equalTo: input.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            context.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), context.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            context.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: context.bottomAnchor, constant: 4), scroll.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -4),
            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor), footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor), footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        panel.contentView = root
        configureWorkspace([]); refreshLocalization()
    }
    required init?(coder: NSCoder) { nil }

    func present(in parent: NSWindow?, initial: [FileNameSearchEntry]) {
        guard let window else { return }
        initialEntries = initial
        query.stringValue = ""; reloadScope()
        returnFocus = parent?.firstResponder
        if let parent {
            parent.addChildWindow(window, ordered: .above)
            let visible = parent.screen?.visibleFrame ?? parent.frame
            let size = NSSize(width: min(760, visible.width - 32), height: min(540, visible.height - 80))
            window.setContentSize(size)
            window.setFrameTopLeftPoint(.init(x: max(visible.minX, min(parent.frame.midX - window.frame.width / 2, visible.maxX - window.frame.width)),
                                             y: min(visible.maxY, max(visible.minY + window.frame.height, parent.frame.maxY - 90))))
        }
        window.appearance = parent?.effectiveAppearance
        dismissal.start(window: window) { [weak self] in self?.dismiss(restoreFocus: false) }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(query)
    }

    func configureWorkspace(_ roots: [WorkspaceRoot]) {
        workspacePaths = roots.filter(\.isAvailable).map(\.canonicalPath)
        scopeTabs[ProjectSearchScope.workspace.rawValue].isEnabled = !workspacePaths.isEmpty
        if workspacePaths.isEmpty && selectedScope == .workspace { selectedScope = .all }
        updateScopeTabs()
        updateContext()
    }
    func selectScope(_ value: ProjectSearchScope) {
        guard value != .workspace || !workspacePaths.isEmpty else { return }
        selectedScope = value; updateScopeTabs(); reloadScope()
    }
    func selectFolder(_ url: URL) {
        folder = url; selectScope(.folder)
    }
    private func includes(_ path: String, under root: String) -> Bool {
        path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    func refreshIndex() { reloadScope() }
    private func reloadScope() {
        task?.cancel(); generation = UUID()
        let selected = selectedScope, selectedFolder = folder
        let folderPath = selectedFolder?.resolvingSymlinksInPath().standardizedFileURL.path
        let seed = initialEntries.filter { entry in
            switch selected {
            case .all: return true
            case .openDocuments: if case .tab = entry.target { return true }; return false
            case .workspace: return workspacePaths.contains { includes(entry.path, under: $0) }
            case .folder: return folderPath.map { includes(entry.path, under: $0) } ?? false
            }
        }
        entries = seed; truncated = false; skipped = 0
        loading = selected != .openDocuments && (selected != .folder || selectedFolder != nil)
        updateContext(); refilter()
        guard loading else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let indexed: (entries: [FileNameSearchEntry], truncated: Bool, skipped: Int)?
                if let request = self.onLoadRequest { indexed = try await request(selected, selected == .folder ? selectedFolder : nil) }
                else if selected != .folder { indexed = try await self.onLoad?() }
                else { indexed = nil }
                guard !Task.isCancelled, self.generation == token else { return }
                if let indexed {
                    var paths = Set<String>()
                    self.entries = (seed + indexed.entries).filter { entry in
                        let key: String
                        if case .tab(let id) = entry.target, !entry.path.hasPrefix("/") { key = "tab:" + id.rawValue.uuidString }
                        else { key = entry.path }
                        return paths.insert(key).inserted
                    }
                    self.truncated = indexed.truncated; self.skipped = indexed.skipped
                }
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.skipped += 1
            }
            self.loading = false; self.refilter()
        }
    }

    func dismiss(restoreFocus: Bool = true) {
        dismissal.stop()
        task?.cancel(); task = nil; generation = UUID()
        filterTask?.cancel(); filterTask = nil; filterGeneration = UUID()
        guard let window else { return }
        let parent = window.parent
        parent?.removeChildWindow(window); window.orderOut(nil)
        if restoreFocus { parent?.makeKeyAndOrderFront(nil); parent?.makeFirstResponder(returnFocus) }
        returnFocus = nil
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        window?.title = catalog.text("Search Files")
        query.placeholderString = catalog.text("Search files by name or path")
        query.setAccessibilityLabel(catalog.text("Search files by name or path"))
        table.setAccessibilityLabel(catalog.text("Files"))
        for (tab, key) in zip(scopeTabs, ["All", "Open Documents", "Workspace", "Folder"]) {
            tab.title = catalog.text(key); tab.setAccessibilityLabel(catalog.text(key))
        }
        scope.setAccessibilityLabel(catalog.text("Scope"))
        browse.title = catalog.text("Browse…")
        clear.toolTip = catalog.text("Clear"); clear.setAccessibilityLabel(catalog.text("Clear"))
        splitButton.title = catalog.text("Open in Right Split"); splitButton.toolTip = catalog.text("Open in Right Split")
        table.toolTip = catalog.text("↑↓ Select · ↵ Open · Esc Close")
        updateContext()
        updateStatus()
    }
    func setQuery(_ value: String) { query.stringValue = value; refilter() }
    private func refilter() {
        filterTask?.cancel(); filterGeneration = UUID()
        let sourceEntries = entries
        clear.isHidden = query.stringValue.isEmpty
        if sourceEntries.count > 500 {
            let token = filterGeneration, source = sourceEntries, text = query.stringValue
            results = []; reloadResults()
            filterTask = Task { [weak self] in
                let worker = Task.detached(priority: .userInitiated) { FileNameSearchEntry.matching(source, query: text) }
                let filtered = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, self.filterGeneration == token else { return }
                self.results = filtered; self.reloadResults()
            }
            return
        }
        results = FileNameSearchEntry.matching(sourceEntries, query: query.stringValue)
        reloadResults()
    }
    private func reloadResults() {
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateStatus(); updateSelection()
    }
    private func updateStatus() {
        empty.isHidden = !results.isEmpty
        empty.stringValue = catalog.text(selectedScope == .folder && folder == nil ? "Choose a folder…" : loading ? "Indexing file names…" : "No matching files")
        status.stringValue = loading ? catalog.text("Indexing file names…")
            : catalog.text(truncated ? "Showing %1$@ files · Index limit reached · Skipped items: %2$@"
                           : "Showing %1$@ files · Skipped items: %2$@", arguments: [String(results.count), String(skipped)])
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CommandPaletteRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("filename")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? SearchResultCell ?? SearchResultCell()
        cell.identifier = id
        let entry = results[row]; cell.apply(title: entry.name, detail: entry.path, project: entry.project, query: query.stringValue)
        return cell
    }
    private func updateContext() {
        let folderScope = selectedScope == .folder
        browse.isHidden = !folderScope
        directory.stringValue = folderScope ? (folder?.path ?? catalog.text("Choose a folder…"))
            : selectedScope == .openDocuments ? "" : catalog.text("Workspace folders: %1$@", arguments: [String(workspacePaths.count)])
        directory.toolTip = folderScope ? folder?.path : selectedScope == .openDocuments ? nil : workspacePaths.joined(separator: "\n")
    }
    private func updateScopeTabs() {
        for (value, tab) in zip(ProjectSearchScope.allCases, scopeTabs) { tab.isOn = value == selectedScope }
    }
    @objc private func browsePressed() {
        task?.cancel(); generation = UUID(); let token = generation
        loading = false; updateStatus()
        task = Task { [weak self] in
            guard let self else { return }
            let chosen = await self.onChooseFolder?()
            guard !Task.isCancelled, self.generation == token else { return }
            guard let chosen else { self.reloadScope(); return }
            self.selectFolder(chosen)
        }
    }
    private func updateSelection() {
        let selected = results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
        selectedPath.stringValue = selected?.path ?? ""; selectedPath.toolTip = selected?.path
        splitButton.isHidden = onOpenInSplit == nil; splitButton.isEnabled = selected != nil
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    @objc private func clearQuery() { query.stringValue = ""; refilter(); window?.makeFirstResponder(query) }
    @objc private func activateInSplit() {
        guard results.indices.contains(table.selectedRow), let onOpenInSplit else { return }
        let entry = results[table.selectedRow]; dismiss(); onOpenInSplit(entry)
    }
    @objc func activateSelection() {
        guard results.indices.contains(table.selectedRow) else { return }
        let result = results[table.selectedRow]; dismiss(); onOpen?(result)
    }
    func controlTextDidChange(_ obj: Notification) { refilter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(results.count - 1, max(0, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }
}
