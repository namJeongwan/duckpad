import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

/// A reusable browser stays open while files are opened in the owning editor.
/// Paths and previews are view state; the server's files are never changed.
@MainActor final class RemoteFilePanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let host = FilteredSuggestionField(symbolName: "server.rack")
    let path = FilteredSuggestionField(symbolName: "folder")
    let tail = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let open = SearchActionButton(frame: .zero)
    let table = NSTableView()
    let preview = NSTextView()
    let status = NSTextField(labelWithString: "")
    private let connect = SearchActionButton(frame: .zero)
    private let cancel = SearchActionButton(frame: .zero)
    private let up = StatusBarButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)!, target: nil, action: nil)
    private let refresh = StatusBarButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)!, target: nil, action: nil)
    private let hidden = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let hostLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private(set) var panel: NSPanel?
    private(set) var listing: RemoteDirectoryListing?
    private var entries: [RemoteDirectoryEntry] = []
    private var connectedHost: String?
    private var port: (any RemoteFileBrowsing)?
    private var onOpen: (@MainActor ([RemoteFileLocation], Bool) async throws -> Void)?
    private var browseTask: Task<Void, Never>?, previewTask: Task<Void, Never>?, openTask: Task<Void, Never>?, catalogTask: Task<Void, Never>?
    private var generation = UUID(), previewGeneration = UUID()
    private var loading = false, opening = false, failed = false
    private let retryPolicy: RemoteConnectionRetryPolicy
    private let defaults: UserDefaults
    private var catalog = L10n.catalog

    init(defaults: UserDefaults = .standard, retryPolicy: RemoteConnectionRetryPolicy = .init()) {
        self.retryPolicy = retryPolicy
        self.defaults = defaults
        super.init()
        for (field, identifier, placeholder) in [(host, "host", "user@server"), (path, "path", "/var/log")] {
            field.placeholderString = placeholder
            field.onChange = { [weak self, weak field] in
                guard let field else { return }
                self?.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
            }
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            field.setAccessibilityIdentifier("duckpad.remote-file." + identifier + ".container")
            field.input.setAccessibilityIdentifier("duckpad.remote-file." + identifier)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 28).isActive = true
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        }
        host.target = self; host.action = #selector(connectHost)
        path.target = self; path.action = #selector(navigatePath)
        connect.target = self; connect.action = #selector(connectHost)
        cancel.target = self; cancel.action = #selector(cancelOperations); cancel.keyEquivalent = "\u{1b}"
        open.target = self; open.action = #selector(openSelection); open.isPrimary = true; open.keyEquivalent = "\r"
        up.target = self; up.action = #selector(parentDirectory)
        refresh.target = self; refresh.action = #selector(navigatePath)
        hidden.target = self; hidden.action = #selector(filterEntries)
        for button in [up, refresh] {
            button.configureAsToolbarIcon()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.headerView = nil; table.style = .plain; table.rowHeight = 28; table.allowsMultipleSelection = true
        table.backgroundColor = WorkspaceColors.panel
        table.usesAlternatingRowBackgroundColors = false
        table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(openSelection)
        table.setAccessibilityIdentifier("duckpad.remote-file.entries")
        preview.isEditable = false; preview.isSelectable = true; preview.isRichText = false
        preview.backgroundColor = WorkspaceColors.editor; preview.textColor = .labelColor
        preview.frame = .init(x: 0, y: 0, width: 400, height: 300)
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textContainerInset = .init(width: 10, height: 10)
        preview.setAccessibilityIdentifier("duckpad.remote-file.preview")
        refreshLocalization()
    }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        hostLabel.stringValue = catalog.text("SSH host")
        pathLabel.stringValue = catalog.text("Remote path")
        host.input.setAccessibilityLabel(hostLabel.stringValue); path.input.setAccessibilityLabel(pathLabel.stringValue)
        host.placeholderString = catalog.text("Filter hosts"); path.placeholderString = catalog.text("Filter folders")
        host.input.toolTip = catalog.text("%1$@ — %2$@", arguments: [hostLabel.stringValue, "⇧⌘L"])
        path.input.toolTip = catalog.text("%1$@ — %2$@", arguments: [pathLabel.stringValue, "⌘L"])
        host.refreshLocalization(catalog: catalog); path.refreshLocalization(catalog: catalog)
        connect.title = catalog.text("Connect")
        cancel.title = catalog.text("Cancel")
        open.title = catalog.text("Open")
        hidden.title = catalog.text("Show hidden files")
        tail.title = catalog.text("Follow file changes (Tail)")
        up.toolTip = catalog.text("%1$@ — %2$@", arguments: [catalog.text("Parent folder"), "⌘↑"])
        up.setAccessibilityLabel(catalog.text("Parent folder"))
        refresh.toolTip = catalog.text("%1$@ — %2$@", arguments: [catalog.text("Refresh"), "⌘R"])
        refresh.setAccessibilityLabel(catalog.text("Refresh"))
        preview.setAccessibilityLabel(catalog.text("File preview"))
        table.setAccessibilityLabel(catalog.text("Remote files"))
        note.stringValue = catalog.text("SSH keys · Read-only · Select multiple files to open · Tail starts with the latest 1 MiB.")
        panel?.title = catalog.text("Open Remote File")
        if connectedHost == nil, !loading { status.stringValue = catalog.text("Choose an SSH host or enter one to connect.") }
        updateControls()
    }

    func show(attachedTo window: NSWindow, browser: any RemoteFileBrowsing, showHiddenFiles: Bool,
              onOpen: @escaping @MainActor ([RemoteFileLocation], Bool) async throws -> Void) {
        self.port = browser; self.onOpen = onOpen
        hidden.state = showHiddenFiles ? .on : .off
        if let panel { filterEntries(); panel.makeKeyAndOrderFront(nil); return }
        let panel = RemoteFileWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 570),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.autorecalculatesKeyViewLoop = false
        panel.titlebarAppearsTransparent = true; panel.backgroundColor = WorkspaceColors.panel
        panel.contentView = SearchSurfaceView(.panel)
        panel.onShortcut = { [weak self] in self?.performShortcut($0) ?? false }
        panel.minSize = .init(width: 720, height: 580)
        panel.title = catalog.text("Open Remote File"); panel.appearance = window.appearance; panel.delegate = self
        let hostRow = NSStackView(views: [hostLabel, host, connect, cancel]); hostRow.spacing = 8
        let pathRow = NSStackView(views: [pathLabel, path, up, refresh]); pathRow.spacing = 8
        for row in [hostRow, pathRow] { row.distribution = .fill; row.alignment = .centerY }
        for field in [host, path] {
            field.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        }
        for label in [hostLabel, pathLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let statusRow = NSStackView(views: [spinner, status, NSView(), hidden]); statusRow.spacing = 8
        let files = NSScrollView(); files.hasVerticalScroller = true; files.documentView = table; files.borderType = .noBorder
        files.backgroundColor = WorkspaceColors.panel
        let content = NSScrollView(); content.hasVerticalScroller = true; content.hasHorizontalScroller = true
        content.documentView = preview; content.borderType = .noBorder
        content.backgroundColor = WorkspaceColors.editor
        for scroll in [files, content] { scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay }
        preview.isVerticallyResizable = true; preview.isHorizontallyResizable = false
        preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        let split = WorkspaceSplitView(frame: .zero); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(files); split.addArrangedSubview(content)
        files.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        content.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let actions = NSStackView(views: [tail, NSView(), open]); actions.spacing = 10
        let stack = NSStackView(views: [hostRow, pathRow, statusRow, split, note, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        hostLabel.widthAnchor.constraint(equalTo: pathLabel.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -16),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        for row in [hostRow, pathRow, statusRow, split, note, actions] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        self.panel = panel
        if host.stringValue.isEmpty { host.stringValue = recentHosts.first ?? "" }
        let parent = window.frame
        panel.setFrameOrigin(.init(x: parent.midX - 400, y: parent.midY - 285))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        host.input.nextKeyView = path.input; path.input.nextKeyView = table; table.nextKeyView = open
        host.focus()
        split.setPosition(300, ofDividerAt: 0)
        preview.string = catalog.text("Select a file to preview its contents.")
        refreshLocalization(catalog: catalog)
        catalogTask = Task { [weak self] in
            do {
                let aliases = try await browser.configuredHosts()
                guard !Task.isCancelled, let self, self.panel != nil else { return }
                self.host.setSuggestions(self.recentHosts + aliases)
            } catch { }
        }
    }

    var recentHosts: [String] {
        (defaults.stringArray(forKey: "remoteFile.recentHosts") ?? []).filter { RemoteFileLocation(host: $0, path: "/") != nil }
    }
    private var destination: String { host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSControl === host {
            let hadListing = connectedHost != nil
            cancelOperations(); connectedHost = nil; listing = nil; path.setSuggestions([])
            if hadListing { path.stringValue = "" }
            failed = false; filterEntries()
        } else if notification.object as? NSControl === path {
            // Typing a destination supersedes an older row selection; a later
            // explicit row click still opens from the displayed listing.
            if loading { cancelOperations() }
            clearSelectionAndPreview()
        }
        updateControls()
    }
    private func updateControls() {
        let valid = RemoteFileLocation(host: destination, path: "/") != nil
        connect.isEnabled = valid && !loading && !opening
        cancel.isEnabled = loading || opening || previewTask != nil
        up.isEnabled = connectedHost == destination && listing != nil && !loading && !opening
        refresh.isEnabled = valid && !loading && !opening
        open.isEnabled = !loading && !opening && valid && (table.selectedRow >= 0 || RemoteFileLocation(host: destination, path: path.stringValue) != nil)
        host.isEnabled = !opening; path.isEnabled = !opening
        if !loading, !opening { connect.title = catalog.text(failed ? "Retry" : connectedHost == nil ? "Connect" : "Reconnect") }
        if loading || opening { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    @objc private func connectHost() {
        let remembered = (defaults.dictionary(forKey: "remoteFile.directories") as? [String: String])?[destination]
        browse(path: path.stringValue.isEmpty ? remembered : path.stringValue, connectFirst: true)
    }
    @objc private func navigatePath() { browse(path: path.stringValue.isEmpty ? nil : path.stringValue) }
    @objc private func parentDirectory() {
        guard let listing else { return }
        browse(path: (listing.path as NSString).deletingLastPathComponent.isEmpty ? "/" : (listing.path as NSString).deletingLastPathComponent)
    }
    private func browse(path requestedPath: String?, connectFirst: Bool = false) {
        guard let port, RemoteFileLocation(host: destination, path: "/") != nil else { return }
        browseTask?.cancel(); previewTask?.cancel(); previewTask = nil
        let id = UUID(), requestedHost = destination, retryPolicy = retryPolicy
        let needsConnection = connectFirst || connectedHost != requestedHost
        generation = id; loading = true; failed = false
        status.stringValue = catalog.text(needsConnection ? "Connecting…" : "Loading folder…"); status.textColor = .secondaryLabelColor
        updateControls()
        browseTask = Task { [weak self] in
            do {
                let onRetry: @Sendable (Int, Int) async -> Void = { [weak self] attempt, total in
                    await MainActor.run {
                        guard let self, self.generation == id, self.panel != nil, !Task.isCancelled else { return }
                        self.status.stringValue = self.catalog.text("Reconnecting… (%1$@/%2$@)", arguments: [String(attempt), String(total)])
                    }
                }
                var result: RemoteDirectoryListing?
                if needsConnection {
                    // Authenticate and establish a usable connection before
                    // considering a typed or remembered path, even an invalid one.
                    do {
                        result = try await retryPolicy.run(operation: {
                            try await port.directory(host: requestedHost, path: nil)
                        }, onRetry: onRetry)
                    } catch FileObservationError.directoryUnavailable {
                        // The remote error confirms authentication even when
                        // HOME is inaccessible. Still try an explicit path.
                        guard !Task.isCancelled, let self, self.generation == id, self.panel != nil else { return }
                        if self.connectedHost != requestedHost { self.listing = nil }
                        self.connectedHost = requestedHost
                        if requestedPath == nil { throw FileObservationError.directoryUnavailable }
                    }
                    guard !Task.isCancelled, let self, self.generation == id, self.panel != nil else { return }
                    if let result { self.presentListing(result, host: requestedHost, updatePath: false) }
                }
                if result == nil || requestedPath != nil && requestedPath != result?.path {
                    guard RemoteFileLocation(host: requestedHost, path: requestedPath ?? "/") != nil else {
                        throw FileObservationError.directoryUnavailable
                    }
                    if let self { self.status.stringValue = self.catalog.text("Loading folder…") }
                    result = try await retryPolicy.run(operation: {
                        try await port.directory(host: requestedHost, path: requestedPath)
                    }, onRetry: onRetry)
                }
                guard !Task.isCancelled, let self, self.generation == id, self.panel != nil else { return }
                guard let result else { throw FileObservationError.invalidResponse }
                self.loading = false; self.browseTask = nil
                self.presentListing(result, host: requestedHost, updatePath: true)
                self.status.stringValue = self.catalog.text(result.isTruncated ? "Connected · Showing the first 5,000 entries" : "Connected · SSH connection shared across files")
            } catch {
                guard let self, self.generation == id, self.panel != nil else { return }
                self.loading = false; self.browseTask = nil
                if error as? FileObservationError == .directoryUnavailable {
                    if self.connectedHost != requestedHost { self.listing = nil }
                    self.connectedHost = requestedHost; self.failed = false
                    self.filterEntries()
                    self.status.stringValue = self.catalog.text("Connected · Folder unavailable. Check the remote path and permissions.")
                } else {
                    self.connectedHost = nil; self.listing = nil; self.failed = true
                    self.filterEntries()
                    self.status.stringValue = error is CancellationError ? self.catalog.text("Cancelled") : self.catalog.text("%1$@ Select Retry to reconnect.", arguments: [((error as? FileObservationError) ?? .unavailable).localizedObservationMessage])
                }
                self.status.textColor = .systemOrange
            }
            self?.updateControls()
        }
    }
    private func presentListing(_ result: RemoteDirectoryListing, host: String, updatePath: Bool) {
        connectedHost = host; listing = result
        if updatePath { path.stringValue = result.path }
        path.setSuggestions(result.entries.filter(\.isDirectory).map { join(result.path, $0.name) })
        filterEntries()
        remember(host: host, directory: result.path)
    }
    private func performShortcut(_ shortcut: String) -> Bool {
        switch shortcut {
        case "cmd+l": if path.isEnabled { path.focus() }
        case "shift+cmd+l": if host.isEnabled { host.focus() }
        case "cmd+r": if refresh.isEnabled { navigatePath() }
        case "cmd+up": if up.isEnabled { parentDirectory() }
        case "cmd+w": dismiss()
        default: return false
        }
        return true
    }
    private func remember(host: String, directory: String) {
        defaults.set(([host] + recentHosts.filter { $0 != host }).prefix(12).map { $0 }, forKey: "remoteFile.recentHosts")
        var directories = (defaults.dictionary(forKey: "remoteFile.directories") as? [String: String]) ?? [:]
        directories[host] = directory
        directories = directories.filter { recentHosts.contains($0.key) }
        defaults.set(directories, forKey: "remoteFile.directories")
    }
    @objc func filterEntries() {
        entries = listing?.entries.filter { hidden.state == .on || !$0.name.hasPrefix(".") } ?? []
        clearSelectionAndPreview(); table.reloadData()
        updateControls()
    }
    private func clearSelectionAndPreview() {
        previewTask?.cancel(); previewTask = nil; previewGeneration = UUID()
        table.deselectAll(nil)
        preview.string = catalog.text("Select a file to preview its contents.")
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { WorkspaceSidebarRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let item = entries[row]
        let identifier = NSUserInterfaceItemIdentifier("remoteEntry")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell.textField?.stringValue = item.name
            cell.imageView?.image = NSImage(systemSymbolName: item.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)
            cell.imageView?.contentTintColor = item.isDirectory ? .systemBlue : .secondaryLabelColor
            return cell
        }
        let cell = NSTableCellView(); cell.identifier = identifier
        let label = NSTextField(labelWithString: item.name)
        label.lineBreakMode = .byTruncatingMiddle; label.font = .systemFont(ofSize: 13)
        let icon = NSImageView(image: NSImage(systemSymbolName: item.isDirectory ? "folder" : "doc.text", accessibilityDescription: nil)!)
        icon.contentTintColor = item.isDirectory ? .systemBlue : .secondaryLabelColor
        let stack = NSStackView(views: [icon, label]); stack.spacing = 7; stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
        cell.textField = label; cell.imageView = icon
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls(); previewSelection()
    }
    private func previewSelection() {
        previewTask?.cancel(); previewTask = nil
        let id = UUID(); previewGeneration = id
        guard let port, let listing, connectedHost == destination, entries.indices.contains(table.selectedRow) else {
            preview.string = catalog.text("Select a file to preview its contents."); return
        }
        let entry = entries[table.selectedRow]
        guard !entry.isDirectory, let location = RemoteFileLocation(host: destination, path: join(listing.path, entry.name)) else {
            preview.string = catalog.text("Select a file to preview its contents."); return
        }
        preview.string = catalog.text("Loading preview…")
        let retryPolicy = retryPolicy
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(70))
                let read = try await retryPolicy.run {
                    try await port.read(.ssh(location), after: nil, maximumBytes: 16 * 1_024)
                }
                var decoder = FileTailUTF8Decoder()
                let data = try decoder.decode(read.data)
                guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw FileObservationError.invalidUTF8 }
                guard !Task.isCancelled, let self, self.previewGeneration == id, self.panel != nil else { return }
                self.preview.string = text
            } catch {
                guard !Task.isCancelled, let self, self.previewGeneration == id, self.panel != nil else { return }
                self.preview.string = ((error as? FileObservationError) ?? .unavailable).localizedObservationMessage
            }
            guard let self, self.previewGeneration == id else { return }
            self.previewTask = nil; self.updateControls()
        }
        updateControls()
    }
    @objc private func openSelection() {
        guard !loading, !opening, let onOpen else { return }
        var files = [RemoteFileLocation]()
        if connectedHost == destination, let listing {
            let selected = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
            if selected.count == 1, selected[0].isDirectory { browse(path: join(listing.path, selected[0].name)); return }
            files = selected.filter { !$0.isDirectory }.compactMap { RemoteFileLocation(host: destination, path: join(listing.path, $0.name)) }
        }
        if files.isEmpty, let direct = RemoteFileLocation(host: destination, path: path.stringValue) { files = [direct] }
        guard !files.isEmpty else { return }
        opening = true; updateControls()
        let follow = tail.state == .on
        openTask = Task { [weak self] in
            defer { self?.opening = false; self?.openTask = nil; self?.updateControls() }
            do {
                try await onOpen(files, follow)
                guard !Task.isCancelled, let self, self.panel != nil else { return }
                self.status.stringValue = self.catalog.text("Opened in the editor. Select another file to continue.")
            } catch {
                guard let self, self.panel != nil else { return }
                self.status.stringValue = error is CancellationError ? self.catalog.text("Cancelled") : ((error as? FileObservationError) ?? .unavailable).localizedObservationMessage
                self.status.textColor = .systemOrange
            }
        }
    }
    private func join(_ directory: String, _ name: String) -> String { (directory == "/" ? "/" : directory + "/") + name }
    @objc func cancelOperations() {
        generation = UUID(); previewGeneration = UUID()
        browseTask?.cancel(); browseTask = nil; previewTask?.cancel(); previewTask = nil; openTask?.cancel()
        loading = false
        status.stringValue = catalog.text("Cancelled")
        updateControls()
    }
    func windowWillClose(_ notification: Notification) { dismiss() }
    @objc func dismiss() {
        host.dismissSuggestions(); path.dismissSuggestions()
        cancelOperations(); catalogTask?.cancel(); catalogTask = nil
        let window = panel; panel = nil
        if let window { window.parent?.removeChildWindow(window); window.orderOut(nil); window.delegate = nil }
        onOpen = nil; port = nil
    }
}
