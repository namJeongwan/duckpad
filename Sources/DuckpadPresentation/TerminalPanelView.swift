import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

/// Owns per-window session controls and terminal surfaces. The injected adapter
/// owns rendering, input and process transport.
@MainActor
final class TerminalPanelView: NSView {
    let sessionTabs = TerminalSessionTabStripView()
    private var preferences = AppSettings.defaults
    private var headerHeight: NSLayoutConstraint?
    private let closeConfirmation: TerminalCloseConfirmation
    private let placeholderScroll = NSScrollView()
    let heading = NSTextField(labelWithString: "")
    let message = NSTextField(wrappingLabelWithString: "")
    let directory = NSTextField(labelWithString: "")
    private struct Snapshot {
        let sessions: [TerminalSessionStore.Session]
        let selectedID: UUID?
        let panes: [UUID: TerminalSessionWorkspaceView.Snapshot]
    }
    private var undoHistory: [Snapshot] = []
    private var redoHistory: [Snapshot] = []
    private let commandPalette = CommandPaletteView()
    private var paletteMenu: NSMenu?
    private var historyExpiry: DispatchWorkItem?
    private let surfaceFactory: ((ShellLaunchConfiguration) -> TerminalSurfaceView?)?
    private var workspaces: [UUID: TerminalSessionWorkspaceView] = [:]
    private let surfaceContainer = NSView()
    private let shell = NSTextField(labelWithString: "")
    private let sessions: TerminalSessionStore
    private var catalog = L10n.catalog
    var onNewSession: (() -> Void)?
    var onWindowAction: ((TerminalAction) -> Void)?
    var onHide: (() -> Void)?

    init(sessions: TerminalSessionStore, surfaceFactory: ((ShellLaunchConfiguration) -> TerminalSurfaceView?)? = nil,
         closeConfirmation: TerminalCloseConfirmation = TerminalCloseConfirmation()) {
        self.closeConfirmation = closeConfirmation
        self.surfaceFactory = surfaceFactory
        self.sessions = sessions
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier("duckpad.terminal.panel")
        sessionTabs.onSelect = { [weak self] id in self?.selectSession(id) }
        sessionTabs.onClose = { [weak self] id in self?.closeSession(id) }
        sessionTabs.contextMenu = { [weak self] id in self?.makeSessionMenu(relativeTo: id) }
        sessionTabs.onHeightChange = { [weak self] height in
            guard let constraint = self?.headerHeight, constraint.constant != height else { return }
            constraint.constant = height
        }
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        for view in [sessionTabs] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        headerHeight = header.heightAnchor.constraint(equalToConstant: 27)
        headerHeight?.isActive = true
        NSLayoutConstraint.activate([
            sessionTabs.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            sessionTabs.topAnchor.constraint(equalTo: header.topAnchor),
            sessionTabs.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            sessionTabs.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        ])

        heading.font = .systemFont(ofSize: 14, weight: .medium)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 0
        shell.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        directory.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        directory.lineBreakMode = .byTruncatingMiddle
        directory.isSelectable = true
        directory.setAccessibilityIdentifier("duckpad.terminal.directory")
        shell.textColor = .secondaryLabelColor
        directory.textColor = .secondaryLabelColor
        let body = NSStackView(views: [heading, message, shell, directory])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false
        let scroll = placeholderScroll
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = TerminalPanelDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        scroll.documentView = document
        addSubview(scroll)
        surfaceContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surfaceContainer)
        NSLayoutConstraint.activate([
            surfaceContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            surfaceContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            surfaceContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            surfaceContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            message.widthAnchor.constraint(equalTo: body.widthAnchor),
            directory.widthAnchor.constraint(equalTo: body.widthAnchor),
            shell.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
        refreshLocalization()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        setAccessibilityLabel(catalog.text("Terminal"))
        reload()
    }

    func reload() {
        sessionTabs.apply(sessions: sessions.sessions, selectedID: sessions.selectedID,
                          preferences: preferences, catalog: catalog)
        heading.stringValue = catalog.text(sessions.selectedSession == nil ? "No terminal sessions" : "Unable to start terminal.")
        message.stringValue = catalog.text(sessions.selectedSession == nil
            ? "Press ⌘T to start a terminal session."
            : "Unable to start terminal.")
        if let configuration = sessions.selectedSession?.configuration {
            shell.stringValue = catalog.text("Shell: %1$@", arguments: [configuration.executable.path])
            directory.stringValue = catalog.text("Working folder: %1$@", arguments: [configuration.workingDirectory.path])
            directory.toolTip = configuration.workingDirectory.path
        } else {
            shell.stringValue = ""
            directory.stringValue = ""
            directory.toolTip = nil
        }
        directory.setAccessibilityLabel(catalog.text("Working Folder"))
        showSelectedSurface()
    }

    var selectedSurface: TerminalSurfaceView? { sessions.selectedID.flatMap { workspaces[$0]?.selectedSurface } }
    var currentWorkingDirectory: URL? { selectedSurface?.workingDirectory }

    func focus() {
        let workspace = sessions.selectedID.flatMap { workspaces[$0] }
        if let workspace { workspace.focus() }
        else if !sessionTabs.focusSelectedTab() { window?.makeFirstResponder(self) }
    }

    private func showSelectedSurface() {
        for (id, workspace) in workspaces { workspace.isHidden = id != sessions.selectedID }
        guard let session = sessions.selectedSession, let surfaceFactory else {
            placeholderScroll.isHidden = false
            surfaceContainer.isHidden = true; return
        }
        if workspaces[session.id] == nil {
            let workspace = TerminalSessionWorkspaceView(configuration: session.configuration, factory: surfaceFactory)
            workspace.onAction = { [weak self] pane, action in self?.handle(action, sessionID: session.id, paneID: pane) }
            workspace.onExit = { [weak self] pane in self?.closePane(sessionID: session.id, paneID: pane, confirm: false) }
            workspaces[session.id] = workspace
        }
        guard let workspace = workspaces[session.id] else { surfaceContainer.isHidden = true; return }
        placeholderScroll.isHidden = true
        surfaceContainer.isHidden = false
        workspace.frame = surfaceContainer.bounds
        workspace.autoresizingMask = [.width, .height]
        if workspace.superview !== surfaceContainer { surfaceContainer.addSubview(workspace) }
        workspace.isHidden = false
    }

    func confirmWindowClose() -> Bool {
        guard workspaces.values.contains(where: { $0.needsCloseConfirmation }) else { return true }
        return closeConfirmation.confirm(multiple: true, catalog: catalog)
    }

    func shutdown() {
        commandPalette.dismiss()
        historyExpiry?.cancel()
        undoHistory.removeAll(); redoHistory.removeAll()
        workspaces.values.forEach { $0.removeFromSuperview(); $0.shutdown() }
        workspaces.removeAll()
    }

    @objc private func newSession() { recordHistory(); onNewSession?() }
    @objc private func hidePanel() { onHide?() }
    private func selectSession(_ id: UUID) {
        sessions.select(id)
        reload()
        focus()
    }
    private func closeSession(_ id: UUID) { closeSessions(.current, relativeTo: id) }

    func closeSessions(_ scope: TerminalSessionCloseScope, relativeTo id: UUID?) {
        let targets = scope.targets(in: sessions.sessions, relativeTo: id)
        guard !targets.isEmpty else { return }
        if targets.contains(where: { workspaces[$0]?.needsCloseConfirmation == true }),
           !closeConfirmation.confirm(multiple: targets.count > 1, catalog: catalog) { return }
        recordHistory()
        targets.forEach { sessions.remove($0) }
        reload()
        focus()
    }

    func makeSessionMenu(relativeTo id: UUID?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: catalog.text(title), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }
        _ = add("New Terminal Session", #selector(newSession))
        menu.addItem(.separator())
        for scope in TerminalSessionCloseScope.allCases {
            let item = add(scope.titleKey, #selector(closeFromMenu(_:)))
            item.identifier = NSUserInterfaceItemIdentifier(scope.rawValue)
            item.representedObject = id
            item.isEnabled = !scope.targets(in: sessions.sessions, relativeTo: id).isEmpty
        }
        menu.addItem(.separator())
        let confirmation = add("Confirm Closing Terminal Sessions", #selector(toggleCloseConfirmation))
        confirmation.state = closeConfirmation.isEnabled ? .on : .off
        _ = add("Hide Terminal", #selector(hidePanel))
        return menu
    }
    @objc private func closeFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.identifier?.rawValue, let scope = TerminalSessionCloseScope(rawValue: raw) else { return }
        closeSessions(scope, relativeTo: sender.representedObject as? UUID)
    }
    @objc private func toggleCloseConfirmation() { closeConfirmation.isEnabled.toggle() }
    override var acceptsFirstResponder: Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { makeSessionMenu(relativeTo: sessions.selectedID) }
    func handleEmptySessionShortcut(_ event: NSEvent) -> Bool {
        guard sessions.sessions.isEmpty, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command {
            switch key {
            case "t": handle(.newTab)
            case "n": onWindowAction?(.newWindow)
            case "z": handle(.undo)
            case "w": onHide?()
            default: return false
            }
            return true
        }
        if flags == [.command, .shift] {
            switch key {
            case "z": handle(.redo)
            case "p": handle(.commandPalette)
            default: return false
            }
            return true
        }
        return false
    }

    private func capture() -> Snapshot {
        Snapshot(sessions: sessions.sessions, selectedID: sessions.selectedID,
                 panes: workspaces.compactMapValues(\.snapshot))
    }
    private func recordHistory() {
        undoHistory.append(capture())
        if undoHistory.count > 20 { undoHistory.removeFirst() }
        redoHistory.removeAll()
        scheduleHistoryExpiry()
    }
    private func scheduleHistoryExpiry() {
        historyExpiry?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.discardHistory() }
        historyExpiry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }
    func discardHistory() {
        historyExpiry?.cancel(); historyExpiry = nil
        undoHistory.removeAll(); redoHistory.removeAll()
        let live = Set(sessions.sessions.map(\.id))
        for id in Array(workspaces.keys) {
            if !live.contains(id), let workspace = workspaces.removeValue(forKey: id) {
                workspace.removeFromSuperview(); workspace.shutdown()
            }
            else { workspaces[id]?.prune(keeping: []) }
        }
    }
    private func restore(_ snapshot: Snapshot) {
        sessions.restore(snapshot.sessions, selectedID: snapshot.selectedID)
        for (id, panes) in snapshot.panes { workspaces[id]?.restore(panes) }
        reload(); focus(); scheduleHistoryExpiry()
    }
    private func closePane(sessionID: UUID, paneID: UUID, confirm: Bool) {
        guard let workspace = workspaces[sessionID] else { return }
        if confirm, workspace.surface(paneID)?.needsCloseConfirmation == true {
            guard closeConfirmation.confirm(multiple: false, catalog: catalog) else { return }
        }
        recordHistory()
        if workspace.remove(paneID) { sessions.remove(sessionID) }
        reload(); focus()
    }
    func handle(_ action: TerminalAction, sessionID: UUID? = nil, paneID: UUID? = nil) {
        switch action {
        case .newTab: newSession(); return
        case .undo:
            guard let state = undoHistory.popLast() else { return }
            redoHistory.append(capture()); restore(state); return
        case .redo:
            guard let state = redoHistory.popLast() else { return }
            undoHistory.append(capture()); restore(state); return
        case .commandPalette: showCommandPalette(); return
        default: break
        }
        guard let id = sessionID ?? sessions.selectedID else { return }
        let workspace = workspaces[id]
        switch action {
        case .newTab: newSession()
        case .closeTab: closeSession(id)
        case .closeSurface:
            if let pane = paneID ?? workspace?.selectedID { closePane(sessionID: id, paneID: pane, confirm: true) }
            else { closeSession(id) }
        case .selectTab(let destination):
            let all = sessions.sessions
            guard !all.isEmpty, let current = all.firstIndex(where: { $0.id == id }) else { return }
            let index: Int
            switch destination {
            case -1: index = (current + all.count - 1) % all.count
            case -2: index = (current + 1) % all.count
            case -3: index = all.count - 1
            default: index = destination - 1
            }
            if all.indices.contains(index) { selectSession(all[index].id) }
        case .split(let direction): recordHistory(); workspace?.split(direction)
        case .focusSplit(let direction): workspace?.focus(direction)
        case .resizeSplit(let direction, let amount): workspace?.resize(direction, amount: amount)
        case .equalizeSplits: workspace?.equalize()
        case .toggleSplitZoom: workspace?.toggleZoom()
        case .undo, .redo, .commandPalette: break
        default: onWindowAction?(action)
        }
    }

    private func showCommandPalette() {
        if commandPalette.isPresented { commandPalette.dismiss(); return }
        let menu = NSMenu(title: catalog.text("Terminal"))
        let commands: [(String, TerminalAction, String, NSEvent.ModifierFlags)] = [
            ("New Terminal Session", .newTab, "t", .command),
            ("Close Terminal Session", .closeTab, "w", [.command, .option]),
            ("Split Terminal Right", .split(.right), "d", .command),
            ("Split Terminal Down", .split(.down), "d", [.command, .shift]),
            ("Equalize Terminal Splits", .equalizeSplits, "=", [.command, .control]),
            ("Toggle Terminal Split Zoom", .toggleSplitZoom, "↩", [.command, .shift]),
            ("Undo", .undo, "z", .command), ("Redo", .redo, "z", [.command, .shift]),
        ]
        for (title, command, key, modifiers) in commands {
            let item = NSMenuItem(title: title, action: #selector(paletteCommand(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self; item.representedObject = TerminalPaletteCommand(command)
            switch command {
            case .newTab: break
            case .undo: item.isEnabled = !undoHistory.isEmpty
            case .redo: item.isEnabled = !redoHistory.isEmpty
            default: item.isEnabled = sessions.selectedID != nil
            }
            menu.addItem(item)
        }
        let bindings: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("Copy", "copy_to_clipboard", "c", .command),
            ("Paste", "paste_from_clipboard", "v", .command), ("Select All", "select_all", "a", .command),
            ("Terminal Search", "start_search", "f", .command),
            ("Find Next", "navigate_search:next", "g", .command),
            ("Find Previous", "navigate_search:previous", "g", [.command, .shift]),
            ("Terminal Inspector", "inspector:toggle", "i", [.command, .option]),
        ]
        for (title, binding, key, modifiers) in bindings {
            let item = NSMenuItem(title: title, action: #selector(paletteBinding(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self; item.representedObject = binding
            item.isEnabled = selectedSurface != nil
            menu.addItem(item)
        }
        MenuLocalization.apply(to: menu, catalog: catalog)
        paletteMenu = menu
        commandPalette.onExecute = { [weak self] item, target in
            self?.focus()
            NSApp.sendAction(item.action!, to: target, from: item)
        }
        if let host = window?.contentView { commandPalette.present(menu: menu, in: host, catalog: catalog) }
    }
    @objc private func paletteBinding(_ sender: NSMenuItem) {
        guard let binding = sender.representedObject as? String, let id = sessions.selectedID else { return }
        _ = workspaces[id]?.selectedSurface?.performBinding(binding)
    }
    @objc private func paletteCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? TerminalPaletteCommand { handle(command.action) }
    }

    func applyPreferences(_ settings: AppSettings) {
        preferences = settings
        sessionTabs.apply(sessions: sessions.sessions, selectedID: sessions.selectedID,
                          preferences: preferences, catalog: catalog)
    }

    override func layout() {
        sessionTabs.maximumHeight = max(27, bounds.height - 96)
        super.layout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = WorkspaceColors.chrome.cgColor
        }
    }
}

private final class TerminalPanelDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class TerminalPaletteCommand: NSObject {
    let action: TerminalAction
    init(_ action: TerminalAction) { self.action = action }
}
