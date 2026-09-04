import AppKit
import DuckpadApplication
import DuckpadDomain

private final class WorkspaceNotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    func invalidate() {
        center.removeObserver(token)
    }

    deinit {
        invalidate()
    }
}

public struct TabWorkspaceSmokeState: Equatable, Sendable {
    public let tabCount: Int
    public let rowCount: Int
    public let selectedTabIsVisible: Bool
}

public struct SearchPanelSmokeState: Equatable, Sendable {
    public let isVisible: Bool
    public let height: Double
}

public struct LanguageStatusSmokeState: Equatable, Sendable {
    public let text: String
    public let isWarning: Bool
}

public struct FileFormatStatusSmokeState: Equatable, Sendable {
    public let text: String
    public let encoding: TextFileEncoding
    public let byteOrderMark: ByteOrderMark
    public let lineEnding: LineEnding
    public let isEnabled: Bool
}

public struct ExtensionStatusSmokeState: Equatable, Sendable {
    public let text: String
    public let isWarning: Bool
    public let commandCount: Int
}

public struct WorkspaceChromeSmokeState: Equatable, Sendable {
    public let documentCount: Int
    public let bannerHeight: Double
    public let tabStripHeight: Double
    public let statusBarHeight: Double
    public let editorOverlapsStatusBar: Bool
    public let interactionsEnabled: Bool
    public let languageStatusEnabled: Bool
    public let extensionStatusEnabled: Bool
}

public struct WorkspaceSidebarSmokeState: Equatable, Sendable {
    public let isVisible: Bool
    public let rootCount: Int
    public let arrangedPaneCount: Int
}

private enum CloseRetryContext {
    /// Stable IDs capture the exact single/bulk command target set without
    /// retaining a stale tab snapshot or AppKit object.
    case tabs([TabID])
    case termination
}

@MainActor
private final class FileDropView: NSView {
    var onFiles: (([URL]) -> Void)?
    var onFolders: (([URL]) -> Void)?
    var onEffectiveAppearanceChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let content = partition(fileURLs(from: sender))
        return (onFiles != nil && !content.files.isEmpty)
            || (onFolders != nil && !content.folders.isEmpty) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        let content = partition(urls)
        var handled = false
        if let onFiles, !content.files.isEmpty {
            onFiles(content.files)
            handled = true
        }
        if let onFolders, !content.folders.isEmpty {
            onFolders(content.folders)
            handled = true
        }
        return handled
    }

    private func partition(_ urls: [URL]) -> (files: [URL], folders: [URL]) {
        var files: [URL] = []
        var folders: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                folders.append(url)
            } else {
                files.append(url)
            }
        }
        return (files, folders)
    }

    private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

@MainActor
public protocol PersistenceErrorPresenting: AnyObject {
    func present(failure: PersistenceFailure, retry: @escaping @MainActor () -> Void)
}

@MainActor
public protocol TabPathActionHandling: AnyObject {
    func copyFullPath(_ path: String)
    func openContainingFolder(for path: String)
}

@MainActor
private final class NativeTabPathActionHandler: TabPathActionHandling {
    func copyFullPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func openContainingFolder(for path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

@MainActor
private final class PersistenceErrorBanner: NSView, PersistenceErrorPresenting {
    private let message = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var retryAction: (@MainActor () -> Void)?
    private var heightConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.14).cgColor
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        message.lineBreakMode = .byTruncatingTail
        message.translatesAutoresizingMaskIntoConstraints = false
        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        addSubview(retryButton)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.leadingAnchor.constraint(greaterThanOrEqualTo: message.trailingAnchor, constant: 8),
            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityIdentifier("duckpad.persistence.error")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present(failure: PersistenceFailure, retry: @escaping @MainActor () -> Void) {
        message.stringValue = "Session \(failure.operation.rawValue) failed: \(failure.cause)"
        retryAction = retry
        heightConstraint.constant = 36
        isHidden = false
    }

    @objc private func retryPressed() {
        isHidden = true
        heightConstraint.constant = 0
        retryAction?()
    }
}

@MainActor
public final class DuckpadWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let workspace: ScratchWorkspaceUseCase
    let tabStrip = MultilineTabStripView(frame: .zero)
    private let fallbackEditor: TextViewEditorAdapter?
    var editor: TextViewEditorAdapter {
        precondition(fallbackEditor != nil, "NSTextView adapter is not active in production composition")
        return fallbackEditor!
    }
    private let activeEditor: any EditorPort
    private let searchPanel = SearchPanelView(frame: .zero)
    private let statusBar = WorkspaceBarView(edge: .top)
    private let persistenceBanner = PersistenceErrorBanner(frame: .zero)
    private let languageStatus = NSButton(title: "Plain Text", target: nil, action: nil)
    private let symbolStatus = NSButton(title: "Symbols", target: nil, action: nil)
    private let fileFormatStatus = NSButton(title: "UTF-8 · No EOL", target: nil, action: nil)
    private let extensionStatus = NSButton(title: "Extensions loading…", target: nil, action: nil)
    private let extensionsPanel = ExtensionsManagerPanel()
    let commandPalettePanel = CommandPalettePanel()
    let symbolOutlinePanel = SymbolOutlinePanel()
    private let workspaceSidebar = WorkspaceSidebarView(frame: .zero)
    private let workspaceContentSplit = NSSplitView(frame: .zero)
    private var searchUseCase: SearchWorkspaceUseCase?
    private let folderSearchUseCase: FolderSearchUseCase?
    private var languageUseCase: LanguageWorkspaceUseCase?
    private let documentIntelligenceUseCase: DocumentIntelligenceUseCase?
    private var extensionUseCase: ExtensionWorkspaceUseCase?
    private var workspaceBrowserUseCase: WorkspaceBrowserUseCase?
    private var extensionState = ExtensionRegistryState(items: [])
    private var hasTornDownWindow = false
    public var onExtensionCommandsChanged: (() -> Void)?
    public var onNewWindowRequested: (() -> Void)?
    public var onSettingsRequested: (() -> Void)?
    public var onBecameKey: (() -> Void)?
    public var onClosed: (() -> Void)?
    public var onDocumentURLUsed: ((URL) -> Void)?
    private let editorHostView: NSView
    private let fileUseCase: FileDocumentUseCase?
    private let filePanels: (any FilePanelPresenting)?
    private let fileConflictPresenter: (any FileConflictPresenting)?
    private let dirtyDecisionPresenter: (any DirtyDocumentDecisionPresenting)?
    private let pathActionHandler: any TabPathActionHandling
    private let navigationPresenter: any EditorNavigationPresenting
    private let recoveryUseCase: SessionRecoveryUseCase?
    private let tabCloseCoordinator: TabCloseCoordinator
    let terminationCoordinator: ApplicationTerminationCoordinator?
    private let approvedWindowClose: @MainActor (NSWindow) -> Void
    private var editorBinding: EditorBindingUseCase!
    private var errorPresenter: (any PersistenceErrorPresenting)!
    private var handledFailureIDs: Set<UUID> = []
    private var startTask: Task<Void, Never>?
    private var permitsNextWindowClose = false
    private var terminationRetrySaveTabID: TabID?
    private var searchTask: Task<Void, Never>?
    private var searchOperationID: UInt64 = 0
    private var languageValidated = false
    private var languageDetectionTask: Task<Void, Never>?
    private var documentIntelligenceTask: Task<Void, Never>?
    private var currentDocumentOutline: DocumentOutline?
    private var appliedThemePalette: EditorThemePalette?
    private var languageState: LanguageServiceState = .degraded("not initialized")
    private var languageStatusIsWarning = false
    private var extensionStatusIsWarning = false
    private var terminationReviewInProgress = false
    private var pendingNewScratchTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCloseTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRestoreClosedTabTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingFolderActivationTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingFileCommandTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingWorkspaceBrowserTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingWorkspaceFileOpenTasks: [UUID: Task<Void, Never>] = [:]
    private var workspaceRestoreTask: Task<Void, Never>?
    private var workspaceNavigationRevisions: [WorkspaceRootID: UInt64] = [:]
    private var accessibilityDisplayObserver: WorkspaceNotificationObservation?

    public init(
        workspace: ScratchWorkspaceUseCase,
        editorAdapter: (any EditorPort)? = nil,
        editorView: NSView? = nil,
        errorPresenter: (any PersistenceErrorPresenting)? = nil,
        fileUseCase: FileDocumentUseCase? = nil,
        filePanels: (any FilePanelPresenting)? = nil,
        fileConflictPresenter: (any FileConflictPresenting)? = nil,
        dirtyDecisionPresenter: (any DirtyDocumentDecisionPresenting)? = nil,
        pathActionHandler: (any TabPathActionHandling)? = nil,
        navigationPresenter: (any EditorNavigationPresenting)? = nil,
        recoveryUseCase: SessionRecoveryUseCase? = nil,
        terminationCoordinator: ApplicationTerminationCoordinator? = nil,
        searchUseCase: SearchWorkspaceUseCase? = nil,
        folderSearchUseCase: FolderSearchUseCase? = nil,
        workspaceBrowserUseCase: WorkspaceBrowserUseCase? = nil,
        languageUseCase: LanguageWorkspaceUseCase? = nil,
        documentIntelligenceUseCase: DocumentIntelligenceUseCase? = nil,
        extensionUseCase: ExtensionWorkspaceUseCase? = nil,
        approvedWindowClose: (@MainActor (NSWindow) -> Void)? = nil,
        automaticallyStarts: Bool = true
    ) {
        self.workspace = workspace
        let fallback = editorAdapter == nil ? TextViewEditorAdapter() : nil
        precondition(
            (editorAdapter == nil) == (editorView == nil),
            "an injected editor port and view must be supplied together"
        )
        fallbackEditor = fallback
        activeEditor = editorAdapter ?? fallback!
        editorHostView = editorView ?? fallback!.scrollView
        self.fileUseCase = fileUseCase
        self.filePanels = filePanels
        self.fileConflictPresenter = fileConflictPresenter
        self.dirtyDecisionPresenter = dirtyDecisionPresenter
        self.pathActionHandler = pathActionHandler ?? NativeTabPathActionHandler()
        self.navigationPresenter = navigationPresenter ?? NativeEditorNavigationPresenter()
        self.recoveryUseCase = recoveryUseCase
        self.searchUseCase = searchUseCase
        self.folderSearchUseCase = folderSearchUseCase
        self.workspaceBrowserUseCase = workspaceBrowserUseCase
        self.languageUseCase = languageUseCase
        self.documentIntelligenceUseCase = documentIntelligenceUseCase
        self.extensionUseCase = extensionUseCase
        tabCloseCoordinator = TabCloseCoordinator(workspace: workspace)
        self.terminationCoordinator = terminationCoordinator
        self.approvedWindowClose = approvedWindowClose ?? { $0.performClose(nil) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Duckpad"
        window.minSize = NSSize(width: 420, height: 280)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        self.errorPresenter = configureContent(injectedPresenter: errorPresenter)
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        let accessibilityToken = workspaceNotifications.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        }
        accessibilityDisplayObserver = WorkspaceNotificationObservation(
            center: workspaceNotifications,
            token: accessibilityToken
        )
        editorBinding = EditorBindingUseCase(workspace: workspace, editor: activeEditor)
        if let foldingEditor = activeEditor as? any FoldingEditorPort {
            foldingEditor.onFoldStateChange = { [weak recoveryUseCase] in
                recoveryUseCase?.editorViewStateDidChange()
            }
        }
        tabStrip.onActivate = { [weak self] id in self?.performActivate(id) }
        tabStrip.onClose = { [weak self] id in self?.performClose(id) }
        tabStrip.onMove = { [weak self] id, index in self?.performMove(id, to: index) }
        tabStrip.onContextAction = { [weak self] id, action in self?.performContextAction(action, for: id) }
        searchPanel.onFind = { [weak self] query in self?.routeFind(query) }
        searchPanel.onReplace = { [weak self] query in self?.routeReplace(query) }
        searchPanel.onReplaceAll = { [weak self] query in self?.routeReplaceAll(query) }
        searchPanel.onFindAll = { [weak self] query in self?.routeFindAll(query) }
        searchPanel.onFindInFolder = { [weak self] query in self?.routeFindInFolder(query) }
        searchPanel.onIncrementalQuery = { [weak self] query in self?.routeFindAll(query, incremental: true) }
        searchPanel.onQueryInvalidated = { [weak self] in self?.cancelSearch() }
        searchPanel.onActivateMatch = { [weak self] match in self?.routeActivateSearchMatch(match) }
        searchPanel.onActivateFolderMatch = { [weak self] document, match in
            self?.routeActivateFolderSearchMatch(document: document, match: match)
        }
        searchPanel.onCancel = { [weak self] in self?.cancelSearch() }
        searchPanel.onClose = { [weak self] in self?.closeSearchPanel() }
        workspaceSidebar.onAddRoot = { [weak self] in self?.performAddWorkspaceFolder(nil) }
        workspaceSidebar.onRemoveRoot = { [weak self] id in self?.routeRemoveWorkspaceRoot(id) }
        workspaceSidebar.onOpenFile = { [weak self] entry in self?.routeOpenWorkspaceEntry(entry) }
        workspaceSidebar.onLoadChildren = { [weak self] rootID, path in
            self?.routeLoadWorkspaceChildren(rootID: rootID, relativeDirectory: path)
        }
        workspaceSidebar.onNavigationChange = { [weak self] rootID, expanded, selected in
            self?.routePersistWorkspaceNavigation(rootID: rootID, expanded: expanded, selected: selected)
        }
        workspaceSidebar.onDropFolder = { [weak self] url in self?.routeAddWorkspaceRoot(url) }
        workspaceSidebar.onRevealPath = { [weak self] path in
            self?.pathActionHandler.openContainingFolder(for: path)
        }
        workspace.onChange = { [weak self] change in self?.handle(change) }
        workspaceBrowserUseCase?.onStateChange = { [weak self] state in self?.renderWorkspaceBrowser(state) }
        languageUseCase?.onStateChange = { [weak self] state in self?.renderLanguageState(state) }
        symbolOutlinePanel.onActivate = { [weak self] symbol in
            guard let self, let outline = self.currentDocumentOutline,
                  self.documentIntelligenceUseCase?.reveal(symbol, in: outline) == true else {
                NSSound.beep()
                return
            }
            self.activeEditor.focus()
        }
        commandPalettePanel.onExecute = { [weak self] item, target in
            guard let self, self.workspaceInteractionsAreActionable,
                  let action = item.action else { return }
            NSApplication.shared.sendAction(action, to: target, from: item)
        }
        extensionUseCase?.onStateChange = { [weak self] state in self?.renderExtensionState(state) }
        extensionsPanel.onSetEnabled = { [weak self] id, enabled in
            Task { @MainActor [weak self] in
                guard let self, self.workspaceInteractionsAreActionable else { return }
                do { try await self.extensionUseCase?.setEnabled(id, enabled: enabled) }
                catch { self.renderExtensionError(error) }
            }
        }
        extensionsPanel.onGrantRequested = { [weak self] item in
            guard self?.workspaceInteractionsAreActionable == true else { return }
            self?.reviewCapabilities(for: item, allow: true)
        }
        extensionsPanel.onRevoke = { [weak self] item in
            guard self?.workspaceInteractionsAreActionable == true else { return }
            self?.reviewCapabilities(for: item, allow: false)
        }
        renderInitial(workspace.snapshot())
        terminationCoordinator?.attach(windowController: self)
        if automaticallyStarts { start() }
    }

    deinit {
        startTask?.cancel()
        searchTask?.cancel()
        languageDetectionTask?.cancel()
        documentIntelligenceTask?.cancel()
        workspaceRestoreTask?.cancel()
        pendingNewScratchTasks.values.forEach { $0.cancel() }
        pendingFolderActivationTasks.values.forEach { $0.cancel() }
        pendingFileCommandTasks.values.forEach { $0.cancel() }
        pendingWorkspaceBrowserTasks.values.forEach { $0.cancel() }
        pendingWorkspaceFileOpenTasks.values.forEach { $0.cancel() }
    }

    public override func close() {
        guard !hasTornDownWindow else { return }
        window?.delegate = nil
        super.close()
        tearDownWindow()
    }

    private func tearDownWindow() {
        guard !hasTornDownWindow else { return }
        hasTornDownWindow = true
        accessibilityDisplayObserver?.invalidate()
        accessibilityDisplayObserver = nil
        documentIntelligenceTask?.cancel()
        documentIntelligenceTask = nil
        documentIntelligenceUseCase?.cancel()
        commandPalettePanel.dismiss()
        symbolOutlinePanel.dismiss()
        if let terminationCoordinator {
            terminationCoordinator.trackWindowCloseCleanup {
                let recoverySaved: Bool
                if let recoveryUseCase = self.recoveryUseCase {
                    if case .saved = await recoveryUseCase.reset() { recoverySaved = true }
                    else { recoverySaved = false }
                } else {
                    recoverySaved = true
                }
                await self.fileUseCase?.releaseAllSecurityScopedAccess()
                return recoverySaved
            }
        } else {
            Task { [fileUseCase] in await fileUseCase?.releaseAllSecurityScopedAccess() }
        }
        terminationCoordinator?.detach(windowController: self)
        workspaceBrowserUseCase?.suspendCommands()
        workspaceRestoreTask?.cancel()
        workspaceRestoreTask = nil
        cancelWorkspaceBrowserTasks()
        window?.delegate = nil
        workspace.onChange = nil
        activeEditor.onEdit = nil
        if let foldingEditor = activeEditor as? any FoldingEditorPort {
            foldingEditor.onFoldStateChange = nil
            foldingEditor.invalidate()
        }
        languageUseCase?.onStateChange = nil
        documentIntelligenceUseCase?.cancel()
        commandPalettePanel.dismiss()
        symbolOutlinePanel.dismiss()
        extensionUseCase?.onStateChange = nil
        workspaceBrowserUseCase?.onStateChange = nil
        editorBinding = nil
        errorPresenter = nil
        tabStrip.tearDownHostedViews()
        let closingWindow = window
        closingWindow?.contentViewController = nil
        closingWindow?.windowController = nil
        window = nil
        onClosed?()
        onClosed = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func showAndFocus() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        editorBinding.render(workspace.snapshot(), requestFocus: true)
    }

    public func tabWorkspaceSmokeState() -> TabWorkspaceSmokeState {
        window?.contentView?.layoutSubtreeIfNeeded()
        tabStrip.layoutSubtreeIfNeeded()
        tabStrip.hostedCollectionView.layoutSubtreeIfNeeded()
        return TabWorkspaceSmokeState(
            tabCount: workspace.snapshot().tabs.count,
            rowCount: tabStrip.rowCount,
            selectedTabIsVisible: tabStrip.selectedTabIsVisible
        )
    }

    public func searchPanelSmokeState() -> SearchPanelSmokeState {
        window?.contentView?.layoutSubtreeIfNeeded()
        return SearchPanelSmokeState(
            isVisible: !searchPanel.isHidden,
            height: searchPanel.frame.height
        )
    }

    public func languageStatusSmokeState() -> LanguageStatusSmokeState {
        LanguageStatusSmokeState(
            text: languageStatus.title,
            isWarning: languageStatusIsWarning
        )
    }

    public func fileFormatStatusSmokeState() -> FileFormatStatusSmokeState {
        let format = activeTextFileFormat
        return FileFormatStatusSmokeState(
            text: fileFormatStatus.title,
            encoding: format.encoding,
            byteOrderMark: format.byteOrderMark,
            lineEnding: format.lineEnding,
            isEnabled: fileFormatStatus.isEnabled
        )
    }

    public func extensionStatusSmokeState() -> ExtensionStatusSmokeState {
        ExtensionStatusSmokeState(text: extensionStatus.title, isWarning: extensionStatusIsWarning,
                                  commandCount: extensionCommands.count)
    }

    public func workspaceChromeSmokeState() -> WorkspaceChromeSmokeState {
        window?.contentView?.layoutSubtreeIfNeeded()
        let editorFrame = editorHostView.convert(editorHostView.bounds, to: window?.contentView)
        let statusFrame = statusBar.convert(statusBar.bounds, to: window?.contentView)
        let overlap = editorFrame.intersection(statusFrame)
        return WorkspaceChromeSmokeState(
            documentCount: tabStrip.documentSwitcher.tabs.count,
            bannerHeight: persistenceBanner.frame.height,
            tabStripHeight: tabStrip.frame.height,
            statusBarHeight: statusBar.frame.height,
            editorOverlapsStatusBar: overlap.width > 0 && overlap.height > 0,
            interactionsEnabled: tabStrip.interactionsEnabled,
            languageStatusEnabled: languageStatus.isEnabled,
            extensionStatusEnabled: extensionStatus.isEnabled
        )
    }

    public func workspaceSidebarSmokeState() -> WorkspaceSidebarSmokeState {
        window?.contentView?.layoutSubtreeIfNeeded()
        return WorkspaceSidebarSmokeState(
            isVisible: workspaceSidebar.superview != nil,
            rootCount: workspaceBrowserUseCase?.roots.count ?? 0,
            arrangedPaneCount: workspaceContentSplit.arrangedSubviews.count
        )
    }

    public func extensionReviewDisclosure(for id: ExtensionID, revoking: Bool) -> String? {
        guard let item = extensionState.items.first(where: { $0.manifest.id == id }) else { return nil }
        let requested = item.manifest.capabilities.map { "\($0.id.rawValue) [\($0.scope.rawValue)]" }.joined(separator: "\n")
        let affected = (try? extensionUseCase?.revocationReviewToken(for: id).affectedPackageIdentities.joined(separator: "\n"))
            ?? "\(item.manifest.id.rawValue)@\(item.manifest.version)#\(item.packageDigest)"
        return "Publisher: \(item.manifest.publisher.id)\nFingerprint: \(item.publisherFingerprint)\nVersion: \(item.manifest.version)\nPackage: \(item.packageDigest)\n\nData access and destination:\n\(requested)\n\nAffected signed package identities:\n\(affected)\n\nGrants last until revoked or identity changes. Publisher revoke is durable across restart until deliberate Reset. No network, filesystem, environment, clock, or process access is exposed."
    }

    public var extensionCommands: [ExtensionCommandContribution] {
        var commands: [ExtensionCommandContribution] = []
        for item in extensionState.items where item.enabled && item.issue == nil {
            for command in item.manifest.contributes.commands {
                let scope: ExtensionCapabilityScope = command.inputScope == .selection ? .selection : .activeDocument
                let read = ExtensionCapabilityRequest(id: .documentsRead, scope: scope)
                let write = ExtensionCapabilityRequest(id: .documentsWrite, scope: scope)
                if item.granted.contains(read), item.granted.contains(write) {
                    commands.append(command)
                }
            }
        }
        return commands.sorted { lhs, rhs in
            lhs.title == rhs.title
                ? lhs.id.rawValue < rhs.id.rawValue
                : lhs.title < rhs.title
        }
    }

    /// Returns the enabled package's declared shortcut for an authorized
    /// command. The native menu remains the final shortcut authority because
    /// it can reject malformed values and collisions with core commands.
    public func extensionKeybinding(for commandID: ExtensionCommandID) -> String? {
        extensionState.items.lazy.compactMap { item -> String? in
            guard item.enabled, item.issue == nil,
                  let command = item.manifest.contributes.commands.first(where: { $0.id == commandID })
            else { return nil }
            let scope: ExtensionCapabilityScope = command.inputScope == .selection ? .selection : .activeDocument
            let read = ExtensionCapabilityRequest(id: .documentsRead, scope: scope)
            let write = ExtensionCapabilityRequest(id: .documentsWrite, scope: scope)
            guard item.granted.contains(read), item.granted.contains(write)
            else { return nil }
            return item.manifest.contributes.keybindings.first(where: {
                $0.command == commandID
            })?.key
        }.first
    }

    @objc public func performShowExtensions(_ sender: Any?) {
        guard workspaceInteractionsAreActionable else { return }
        extensionsPanel.show(relativeTo: window)
    }

    @objc public func performExtensionCommand(_ sender: NSMenuItem) {
        guard !terminationReviewInProgress else { return }
        guard let raw = sender.representedObject as? String else { return }
        let id = ExtensionCommandID(rawValue: raw)
        Task { @MainActor [weak self] in
            guard let self, !self.terminationReviewInProgress else { return }
            do { _ = try await self.extensionUseCase?.invoke(id) }
            catch { self.renderExtensionError(error) }
        }
    }

    public var languageDefinitions: [LanguageDefinition] { languageUseCase?.registry.definitions ?? [] }

    @objc public func performAutomaticLanguage(_ sender: Any?) {
        guard workspaceInteractionsAreActionable else { return }
        Task { @MainActor [weak self] in
            guard let self, self.workspaceInteractionsAreActionable else { return }
            _ = await self.languageUseCase?.setOverride(.automatic)
        }
    }

    @objc public func performChooseLanguage(_ sender: NSMenuItem) {
        guard workspaceInteractionsAreActionable,
              let raw = sender.representedObject as? String else { return }
        Task { @MainActor [weak self] in
            guard let self, self.workspaceInteractionsAreActionable else { return }
            _ = await self.languageUseCase?.setOverride(.manual(LanguageID(rawValue: raw)))
        }
    }

    @objc public func performToggleLineComment(_ sender: Any?) {
        guard workspaceInteractionsAreActionable else { return }
        _ = languageUseCase?.toggleLineComment()
    }

    @objc public func performShowLanguageChooser(_ sender: Any?) {
        guard workspaceInteractionsAreActionable else { return }
        let menu = makeLanguageStatusMenu()
        menu.popUp(
            positioning: menu.items.first(where: { $0.state == .on }),
            at: NSPoint(x: languageStatus.bounds.minX, y: languageStatus.bounds.maxY + 3),
            in: languageStatus
        )
    }

    func start() {
        startTask = Task { [weak self] in
            guard let self else { return }
            if let recoveryUseCase {
                let outcome = await recoveryUseCase.start()
                if case .failed(let failure) = outcome {
                    presentRecoveryStartupFailure(failure)
                }
            } else {
                _ = await workspace.start()
            }
            _ = await fileUseCase?.restoreSecurityScopedAccessForOpenDocuments()
            _ = await workspaceBrowserUseCase?.start()
            await extensionUseCase?.refresh()
        }
    }

    public func waitForStartup() async { await startTask?.value }

    func performAdd() {
        guard workspace.snapshot().startup == .ready, !terminationReviewInProgress else { return }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingNewScratchTasks.removeValue(forKey: token) }
            guard !self.terminationReviewInProgress,
                  self.workspace.snapshot().startup == .ready else { return }
            if case .applied = await self.workspace.addScratch() {
                self.activeEditor.focus()
            }
        }
        pendingNewScratchTasks[token] = task
    }

    @objc public func performNewScratch(_ sender: Any? = nil) {
        performAdd()
    }

    @objc public func performNewWindow(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        onNewWindowRequested?()
    }

    @objc public func performShowSettings(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        onSettingsRequested?()
    }

    func performActivate(_ id: TabID) {
        guard workspaceInteractionsAreActionable else { return }
        Task { @MainActor [weak self] in
            guard let self, self.workspaceInteractionsAreActionable else { return }
            if case .applied = await self.workspace.activate(tabID: id) {
                self.activeEditor.focus()
            }
        }
    }

    @discardableResult
    func performClose(_ id: TabID, decision: CloseDecision? = nil) -> Task<Void, Never> {
        guard workspaceInteractionsAreActionable else { return Task {} }
        return performClose(tabIDs: [id], decision: decision)
    }

    @discardableResult
    private func performClose(
        tabIDs: [TabID],
        decision: CloseDecision? = nil
    ) -> Task<Void, Never> {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingCloseTasks.removeValue(forKey: token) }
            await self.requestClose(
                tabIDs: tabIDs,
                retryingSaveTabID: nil,
                forcedDecision: decision
            )
        }
        pendingCloseTasks[token] = task
        return task
    }

    private func performClose(scope: TabCloseScope, relativeTo tabID: TabID) {
        guard workspaceInteractionsAreActionable else { return }
        let targets = workspace.tabIDs(for: scope, relativeTo: tabID)
        guard !targets.isEmpty else { return }
        performClose(tabIDs: targets)
    }

    @objc public func performCloseActiveTab(_ sender: Any? = nil) {
        guard let id = workspace.snapshot().tabs.first(where: \.isActive)?.id else { return }
        performClose(id)
    }

    @objc public func performCloseAllTabs(_ sender: Any? = nil) { performActiveCloseScope(.all) }
    @objc public func performCloseOtherTabs(_ sender: Any? = nil) { performActiveCloseScope(.others) }
    @objc public func performCloseTabsToLeft(_ sender: Any? = nil) { performActiveCloseScope(.left) }
    @objc public func performCloseTabsToRight(_ sender: Any? = nil) { performActiveCloseScope(.right) }
    @objc public func performCloseUnchangedTabs(_ sender: Any? = nil) { performActiveCloseScope(.unchanged) }
    @objc public func performCloseUnpinnedTabs(_ sender: Any? = nil) { performActiveCloseScope(.unpinned) }

    private func performActiveCloseScope(_ scope: TabCloseScope) {
        guard let id = workspace.snapshot().tabs.first(where: \.isActive)?.id else { return }
        performClose(scope: scope, relativeTo: id)
    }

    @objc public func performRestoreLastClosedTab(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable,
              workspace.canRestoreRecentlyClosedTab else { return }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingRestoreClosedTabTasks.removeValue(forKey: token) }
            guard !self.terminationReviewInProgress,
                  self.workspace.snapshot().startup == .ready,
                  self.workspace.canRestoreRecentlyClosedTab else { return }
            if case .applied = await self.workspace.restoreLastClosedTab() {
                _ = await self.fileUseCase?.restoreSecurityScopedAccessForOpenDocuments()
            }
        }
        pendingRestoreClosedTabTasks[token] = task
    }

    @objc public func performNextTab(_ sender: Any? = nil) {
        navigateTabs(.next)
    }

    @objc public func performPreviousTab(_ sender: Any? = nil) {
        navigateTabs(.previous)
    }

    @objc public func performLastUsedTab(_ sender: Any? = nil) {
        navigateTabs(.lastUsed)
    }

    @objc public func performShowDocumentSwitcher(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable else { return }
        tabStrip.documentSwitcher.showDocumentSwitcher()
    }

    @objc public func performShowCommandPalette(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable,
              let menu = NSApplication.shared.mainMenu else { return }
        commandPalettePanel.present(
            menu: menu,
            excludingAction: #selector(performShowCommandPalette(_:)),
            relativeTo: tabStrip.documentSwitcher
        )
    }

    public func applicationMainMenuDidChange(_ menu: NSMenu) {
        commandPalettePanel.refreshIfPresented(
            menu: menu,
            excludingAction: #selector(performShowCommandPalette(_:))
        )
    }

    @objc public func performCompleteCurrentDocumentWord(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable,
              let documentIntelligenceUseCase else { return }
        documentIntelligenceTask?.cancel()
        let terms = languageUseCase?.activeCompletionTerms ?? []
        documentIntelligenceTask = Task { @MainActor [weak self] in
            let outcome = await documentIntelligenceUseCase.complete(supplementalTerms: terms)
            guard let self, !Task.isCancelled, self.workspaceInteractionsAreActionable else { return }
            switch outcome {
            case .overBudget(let actual, let maximum):
                self.setStatus(
                    self.symbolStatus,
                    text: "Completion paused · \(actual / 1_024 / 1_024) MiB",
                    warning: true
                )
                self.symbolStatus.toolTip = "Completion limit: \(maximum) bytes"
            case .noPrefix, .noMatches:
                NSSound.beep()
            case .presented, .unavailable, .stale:
                break
            }
        }
    }

    @objc public func performShowDocumentSymbols(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable,
              let documentIntelligenceUseCase else { return }
        documentIntelligenceTask?.cancel()
        documentIntelligenceTask = Task { @MainActor [weak self] in
            let outcome = await documentIntelligenceUseCase.outline()
            guard let self, !Task.isCancelled, self.workspaceInteractionsAreActionable else { return }
            switch outcome {
            case .ready(let outline):
                self.currentDocumentOutline = outline
                self.setStatus(
                    self.symbolStatus,
                    text: outline.symbols.isEmpty ? "Symbols" : "Symbols \(outline.symbols.count)",
                    warning: false
                )
                self.symbolStatus.setAccessibilityValue("\(outline.symbols.count) current document symbols")
                self.symbolOutlinePanel.present(symbols: outline.symbols, relativeTo: self.symbolStatus)
            case .overBudget(let actual, let maximum):
                self.setStatus(
                    self.symbolStatus,
                    text: "Symbols paused · \(actual / 1_024 / 1_024) MiB",
                    warning: true
                )
                self.symbolStatus.toolTip = "Symbol outline limit: \(maximum) bytes"
                NSSound.beep()
            case .unavailable, .stale:
                break
            }
        }
    }

    @objc public func performMoveActiveTabLeft(_ sender: Any? = nil) {
        moveActiveTab(by: -1)
    }

    @objc public func performMoveActiveTabRight(_ sender: Any? = nil) {
        moveActiveTab(by: 1)
    }

    @objc public func performOpenFile(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable else { return }
        beginFileCommandTask { [weak self] in await self?.routeOpenFile() }
    }

    @objc public func performOpenAsUTF8(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable else { return }
        beginFileCommandTask { [weak self] in await self?.routeOpenFile(encodingHint: .utf8) }
    }

    @objc public func performOpenAsUTF16LittleEndian(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable else { return }
        beginFileCommandTask { [weak self] in
            await self?.routeOpenFile(encodingHint: .utf16LittleEndian)
        }
    }

    @objc public func performOpenAsUTF16BigEndian(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable else { return }
        beginFileCommandTask { [weak self] in
            await self?.routeOpenFile(encodingHint: .utf16BigEndian)
        }
    }

    @objc public func performConvertToUTF8(_ sender: Any? = nil) {
        routeFileFormatConversion(encoding: .utf8, byteOrderMark: .absent)
    }

    @objc public func performConvertToUTF8BOM(_ sender: Any? = nil) {
        routeFileFormatConversion(encoding: .utf8, byteOrderMark: .present)
    }

    @objc public func performConvertToUTF16LittleEndian(_ sender: Any? = nil) {
        routeFileFormatConversion(encoding: .utf16LittleEndian, byteOrderMark: .present)
    }

    @objc public func performConvertToUTF16LittleEndianWithoutBOM(_ sender: Any? = nil) {
        routeFileFormatConversion(encoding: .utf16LittleEndian, byteOrderMark: .absent)
    }

    @objc public func performConvertToUTF16BigEndian(_ sender: Any? = nil) {
        routeFileFormatConversion(encoding: .utf16BigEndian, byteOrderMark: .present)
    }

    @objc public func performConvertToUTF16BigEndianWithoutBOM(_ sender: Any? = nil) {
        routeFileFormatConversion(encoding: .utf16BigEndian, byteOrderMark: .absent)
    }

    @objc public func performConvertToLF(_ sender: Any? = nil) {
        routeFileFormatConversion(lineEnding: .lf)
    }

    @objc public func performConvertToCRLF(_ sender: Any? = nil) {
        routeFileFormatConversion(lineEnding: .crlf)
    }

    @objc public func performConvertToCR(_ sender: Any? = nil) {
        routeFileFormatConversion(lineEnding: .cr)
    }

    @objc public func performShowFileFormatMenu(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable, fileUseCase != nil else { return }
        let menu = DuckpadMainMenuFactory.makeFormatMenu(target: self)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: fileFormatStatus.bounds.height + 2),
            in: fileFormatStatus
        )
    }

    @objc public func performAddWorkspaceFolder(_ sender: Any? = nil) {
        guard workspaceBrowserCommandsAreActionable,
              let panels = filePanels,
              let workspaceBrowserUseCase else { return }
        let windowReference = WeakWindowReference(window)
        beginWorkspaceBrowserTask { [weak self] in
            let url = await panels.chooseWorkspaceFolderURL(attachedTo: windowReference)
            guard let self, let url, self.workspaceBrowserCommandsAreActionable,
                  !Task.isCancelled else { return }
            _ = await workspaceBrowserUseCase.addRoot(url)
        }
    }

    @objc public func performRemoveWorkspaceFolder(_ sender: Any? = nil) {
        guard let rootID = workspaceSidebar.selectedRootID else { return }
        routeRemoveWorkspaceRoot(rootID)
    }

    @objc public func performToggleWorkspaceSidebar(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        if workspaceSidebar.superview != nil {
            workspaceContentSplit.removeArrangedSubview(workspaceSidebar)
            workspaceSidebar.removeFromSuperview()
        } else {
            workspaceContentSplit.insertArrangedSubview(workspaceSidebar, at: 0)
            workspaceContentSplit.setPosition(220, ofDividerAt: 0)
        }
    }

    @objc public func performSaveFile(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable,
              let context = workspace.activeFileContext() else { return }
        beginFileCommandTask { [weak self] in
            await self?.routeAcceptedSaveFile(expectedContext: context)
        }
    }

    @objc public func performSaveFileAs(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable,
              let context = workspace.activeFileContext() else { return }
        beginFileCommandTask { [weak self] in
            await self?.routeAcceptedSaveFileAs(expectedContext: context)
        }
    }

    @objc public func performSaveCopyAs(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable,
              let context = workspace.activeFileContext() else { return }
        beginFileCommandTask { [weak self] in
            await self?.routeSaveCopyAs(expectedContext: context)
        }
    }

    @objc public func performSaveAll(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable, fileUseCase != nil else { return }
        beginFileCommandTask { [weak self] in
            await self?.routeSaveAll()
        }
    }

    @objc public func performShowFind(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        searchPanel.show(replace: false)
    }
    @objc public func performShowReplace(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        searchPanel.show(replace: true)
    }
    @objc public func performFindNext(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        if searchPanel.isHidden { searchPanel.show(replace: false); return }
        routeFind(searchPanel.currentQuery())
    }
    @objc public func performFindPrevious(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        if searchPanel.isHidden { searchPanel.show(replace: false); return }
        routeFind(searchPanel.currentQuery(direction: .backward))
    }
    @objc public func performCloseFindPanel(_ sender: Any? = nil) {
        closeSearchPanel()
    }

    @objc public func performGoToLine(_ sender: Any? = nil) {
        guard let editor = actionableNavigationEditor,
              let position = editor.navigationPosition,
              let window,
              let bufferID = workspace.snapshot().activeBuffer?.bufferID else { return }
        navigationPresenter.presentLineAndColumn(current: position, in: window) { [weak self] line, column in
            guard let self,
                  self.workspace.snapshot().activeBuffer?.bufferID == bufferID,
                  let editor = self.actionableNavigationEditor else { return }
            if editor.goTo(line: line, column: column, in: position.contextID) {
                self.recoveryUseCase?.editorViewStateDidChange()
            } else {
                NSSound.beep()
            }
        }
    }

    @objc public func performGoToOffset(_ sender: Any? = nil) {
        guard let editor = actionableNavigationEditor,
              let position = editor.navigationPosition,
              let window,
              let bufferID = workspace.snapshot().activeBuffer?.bufferID else { return }
        navigationPresenter.presentUTF8Offset(current: position, in: window) { [weak self] offset in
            guard let self,
                  self.workspace.snapshot().activeBuffer?.bufferID == bufferID,
                  let editor = self.actionableNavigationEditor else { return }
            if editor.goTo(utf8Offset: offset, in: position.contextID) {
                self.recoveryUseCase?.editorViewStateDidChange()
            } else {
                NSSound.beep()
            }
        }
    }

    @objc public func performFindInFolder(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        if searchPanel.isHidden { searchPanel.show(replace: false) }
        let query = searchPanel.currentQuery()
        guard !query.pattern.isEmpty else {
            searchPanel.presentStatus("Enter text, then choose Find in Folder again")
            searchPanel.focusFind()
            return
        }
        routeFindInFolder(query)
    }

    @objc public func performUndo(_ sender: Any? = nil) { performEditorCommand(.undo) }
    @objc public func performRedo(_ sender: Any? = nil) { performEditorCommand(.redo) }
    @objc public func performCut(_ sender: Any? = nil) { performEditorCommand(.cut) }
    @objc public func performCopy(_ sender: Any? = nil) { performEditorCommand(.copy) }
    @objc public func performPaste(_ sender: Any? = nil) { performEditorCommand(.paste) }
    @objc public func performDelete(_ sender: Any? = nil) { performEditorCommand(.delete) }
    @objc public func performSelectAll(_ sender: Any? = nil) { performEditorCommand(.selectAll) }
    @objc public func performDuplicateLine(_ sender: Any? = nil) { performEditorCommand(.duplicateLine) }
    @objc public func performMoveLineUp(_ sender: Any? = nil) { performEditorCommand(.moveLineUp) }
    @objc public func performMoveLineDown(_ sender: Any? = nil) { performEditorCommand(.moveLineDown) }
    @objc public func performDeleteLine(_ sender: Any? = nil) { performEditorCommand(.deleteLine) }
    @objc public func performJoinLines(_ sender: Any? = nil) { performEditorCommand(.joinLines) }
    @objc public func performUppercase(_ sender: Any? = nil) { performEditorCommand(.uppercase) }
    @objc public func performLowercase(_ sender: Any? = nil) { performEditorCommand(.lowercase) }
    @objc public func performIndent(_ sender: Any? = nil) { performEditorCommand(.indent) }
    @objc public func performUnindent(_ sender: Any? = nil) { performEditorCommand(.unindent) }
    @objc public func performTrimTrailingWhitespace(_ sender: Any? = nil) { performEditorCommand(.trimTrailingWhitespace) }

    @objc public func performToggleWordWrap(_ sender: Any? = nil) {
        guard let editor = actionableEditorViewOptions else { return }
        editor.setWordWrapEnabled(!editor.isWordWrapEnabled)
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performToggleWrapMarker(_ sender: Any? = nil) {
        guard let editor = actionableEditorViewOptions,
              editor.supportsWrapMarker else { return }
        editor.setWrapMarkerVisible(!editor.isWrapMarkerVisible)
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performToggleWhitespace(_ sender: Any? = nil) {
        guard let editor = actionableDisplayOptions else { return }
        editor.setWhitespaceVisible(!editor.isWhitespaceVisible)
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performToggleLineEndings(_ sender: Any? = nil) {
        guard let editor = actionableDisplayOptions else { return }
        editor.setLineEndingsVisible(!editor.areLineEndingsVisible)
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performZoomIn(_ sender: Any? = nil) {
        guard let editor = actionableDisplayOptions, editor.zoomLevel < 20 else { return }
        editor.setZoomLevel(editor.zoomLevel + 1)
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performZoomOut(_ sender: Any? = nil) {
        guard let editor = actionableDisplayOptions, editor.zoomLevel > -10 else { return }
        editor.setZoomLevel(editor.zoomLevel - 1)
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performResetZoom(_ sender: Any? = nil) {
        guard let editor = actionableDisplayOptions, editor.zoomLevel != 0 else { return }
        editor.setZoomLevel(0)
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performCollapseCurrentFold(_ sender: Any? = nil) {
        guard let editor = actionableFoldingEditor,
              editor.canCollapseCurrentFold,
              editor.collapseCurrentFold() else { return }
        editor.focus()
    }

    @objc public func performExpandCurrentFold(_ sender: Any? = nil) {
        guard let editor = actionableFoldingEditor,
              editor.canExpandCurrentFold,
              editor.expandCurrentFold() else { return }
        editor.focus()
    }

    @objc public func performCollapseAllFolds(_ sender: Any? = nil) {
        guard let editor = actionableFoldingEditor,
              editor.supportsFolding,
              editor.collapseAllFolds() else { return }
        editor.focus()
    }

    @objc public func performExpandAllFolds(_ sender: Any? = nil) {
        guard let editor = actionableFoldingEditor,
              editor.hasCollapsedFolds,
              editor.expandAllFolds() else { return }
        editor.focus()
    }

    @objc public func performSplitEditorRight(_ sender: Any? = nil) {
        guard let editor = actionableSplitEditor else { return }
        editor.split(orientation: .sideBySide)
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performSplitEditorDown(_ sender: Any? = nil) {
        guard let editor = actionableSplitEditor else { return }
        editor.split(orientation: .stacked)
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performFocusOtherEditorPane(_ sender: Any? = nil) {
        actionableSplitEditor?.focusOtherPane()
    }

    @objc public func performCloseEditorSplit(_ sender: Any? = nil) {
        guard let editor = actionableSplitEditor, editor.splitOrientation != nil else { return }
        editor.closeSplit()
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performToggleBookmark(_ sender: Any? = nil) {
        guard let editor = actionableBookmarkEditor else { return }
        editor.toggleBookmarkAtCaret()
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performNextBookmark(_ sender: Any? = nil) {
        guard let editor = actionableBookmarkEditor,
              editor.navigateToBookmark(forward: true) else { return }
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performPreviousBookmark(_ sender: Any? = nil) {
        guard let editor = actionableBookmarkEditor,
              editor.navigateToBookmark(forward: false) else { return }
        recoveryUseCase?.editorViewStateDidChange()
    }

    @objc public func performClearBookmarks(_ sender: Any? = nil) {
        guard let editor = actionableBookmarkEditor, editor.hasBookmarks else { return }
        editor.clearBookmarks()
        recoveryUseCase?.editorViewStateDidChange()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let command = editorCommand(for: menuItem.action) {
            return actionableEditorCommands?.canPerform(command) ?? false
        }
        if let choice = fileEncodingChoice(for: menuItem.action) {
            let current = activeTextFileFormat
            menuItem.state = current.encoding == choice.encoding
                && current.byteOrderMark == choice.byteOrderMark ? .on : .off
            return workspaceInteractionsAreActionable && fileUseCase != nil
        }
        if let lineEnding = fileLineEndingChoice(for: menuItem.action) {
            menuItem.state = activeTextFileFormat.lineEnding == lineEnding ? .on : .off
            return workspaceInteractionsAreActionable && fileUseCase != nil
        }
        if isOpenUsingEncodingAction(menuItem.action) {
            return workspaceInteractionsAreActionable && fileUseCase != nil && filePanels != nil
        }
        if menuItem.action == #selector(performNewScratch(_:)) {
            return workspace.snapshot().startup == .ready && !terminationReviewInProgress
        }
        if menuItem.action == #selector(performNewWindow(_:)) {
            return !terminationReviewInProgress
        }
        if menuItem.action == #selector(performShowSettings(_:)) {
            return !terminationReviewInProgress && onSettingsRequested != nil
        }
        if menuItem.action == #selector(performRestoreLastClosedTab(_:)) {
            return workspaceInteractionsAreActionable && workspace.canRestoreRecentlyClosedTab
        }
        if let scope = closeScope(for: menuItem.action) {
            guard workspaceInteractionsAreActionable,
                  let active = workspace.snapshot().tabs.first(where: \.isActive)?.id else { return false }
            return !workspace.tabIDs(for: scope, relativeTo: active).isEmpty
        }
        switch menuItem.action {
        case #selector(performCloseActiveTab(_:)),
             #selector(performNextTab(_:)),
             #selector(performPreviousTab(_:)),
             #selector(performLastUsedTab(_:)),
             #selector(performShowDocumentSwitcher(_:)),
             #selector(performShowCommandPalette(_:)),
             #selector(performMoveActiveTabLeft(_:)),
             #selector(performMoveActiveTabRight(_:)),
             #selector(performOpenFile(_:)),
             #selector(performSaveFile(_:)),
             #selector(performSaveFileAs(_:)),
             #selector(performSaveCopyAs(_:)),
             #selector(performToggleLineComment(_:)),
             #selector(performShowLanguageChooser(_:)),
             #selector(performShowExtensions(_:)):
            return workspaceInteractionsAreActionable
        case #selector(performSaveAll(_:)):
            return workspaceInteractionsAreActionable && fileUseCase != nil
                && workspace.snapshot().tabs.contains(where: \.isDirty)
        case #selector(performCompleteCurrentDocumentWord(_:)),
             #selector(performShowDocumentSymbols(_:)):
            return workspaceInteractionsAreActionable && documentIntelligenceUseCase != nil
        case #selector(performAddWorkspaceFolder(_:)):
            guard let workspaceBrowserUseCase else { return false }
            return workspaceBrowserCommandsAreActionable
                && workspaceBrowserUseCase.roots.count < WorkspaceRoot.maximumRootCount
        case #selector(performRemoveWorkspaceFolder(_:)):
            return workspaceBrowserCommandsAreActionable && workspaceSidebar.selectedRootID != nil
        case #selector(performToggleWorkspaceSidebar(_:)):
            menuItem.state = workspaceSidebar.superview == nil ? .off : .on
            return !terminationReviewInProgress
        case #selector(performShowFind(_:)),
             #selector(performShowReplace(_:)),
             #selector(performFindNext(_:)),
             #selector(performFindPrevious(_:)),
             #selector(performFindInFolder(_:)):
            return !terminationReviewInProgress
        case #selector(performGoToLine(_:)),
             #selector(performGoToOffset(_:)):
            return actionableNavigationEditor?.navigationPosition != nil
        case #selector(performToggleBookmark(_:)):
            return actionableBookmarkEditor != nil
        case #selector(performNextBookmark(_:)),
             #selector(performPreviousBookmark(_:)),
             #selector(performClearBookmarks(_:)):
            return actionableBookmarkEditor?.hasBookmarks == true
        case #selector(performToggleWordWrap(_:)):
            guard let editor = actionableEditorViewOptions else {
                menuItem.state = .off
                return false
            }
            menuItem.state = editor.isWordWrapEnabled ? .on : .off
            return true
        case #selector(performToggleWrapMarker(_:)):
            guard let editor = actionableEditorViewOptions else {
                menuItem.state = .off
                return false
            }
            menuItem.state = editor.isWrapMarkerVisible ? .on : .off
            return editor.supportsWrapMarker
        case #selector(performToggleWhitespace(_:)):
            guard let editor = actionableDisplayOptions else { menuItem.state = .off; return false }
            menuItem.state = editor.isWhitespaceVisible ? .on : .off
            return true
        case #selector(performToggleLineEndings(_:)):
            guard let editor = actionableDisplayOptions else { menuItem.state = .off; return false }
            menuItem.state = editor.areLineEndingsVisible ? .on : .off
            return true
        case #selector(performZoomIn(_:)):
            return actionableDisplayOptions.map { $0.zoomLevel < 20 } ?? false
        case #selector(performZoomOut(_:)):
            return actionableDisplayOptions.map { $0.zoomLevel > -10 } ?? false
        case #selector(performResetZoom(_:)):
            return actionableDisplayOptions.map { $0.zoomLevel != 0 } ?? false
        case #selector(performCollapseCurrentFold(_:)):
            return actionableFoldingEditor?.canCollapseCurrentFold == true
        case #selector(performExpandCurrentFold(_:)):
            return actionableFoldingEditor?.canExpandCurrentFold == true
        case #selector(performCollapseAllFolds(_:)):
            return actionableFoldingEditor?.supportsFolding == true
        case #selector(performExpandAllFolds(_:)):
            return actionableFoldingEditor.map { $0.supportsFolding && $0.hasCollapsedFolds } ?? false
        case #selector(performSplitEditorRight(_:)):
            guard let editor = actionableSplitEditor else { menuItem.state = .off; return false }
            menuItem.state = editor.splitOrientation == .sideBySide ? .on : .off
            return true
        case #selector(performSplitEditorDown(_:)):
            guard let editor = actionableSplitEditor else { menuItem.state = .off; return false }
            menuItem.state = editor.splitOrientation == .stacked ? .on : .off
            return true
        case #selector(performFocusOtherEditorPane(_:)),
             #selector(performCloseEditorSplit(_:)):
            return actionableSplitEditor?.splitOrientation != nil
        default:
            return true
        }
    }

    private var actionableEditorViewOptions: (any EditorViewOptionsPort)? {
        guard editorCommandsAreActionable else { return nil }
        return activeEditor as? any EditorViewOptionsPort
    }

    private var actionableBookmarkEditor: (any BookmarkEditorPort)? {
        guard editorCommandsAreActionable else { return nil }
        return activeEditor as? any BookmarkEditorPort
    }

    private var actionableSplitEditor: (any SplitEditorPort)? {
        guard editorCommandsAreActionable else { return nil }
        return activeEditor as? any SplitEditorPort
    }

    private var actionableNavigationEditor: (any EditorNavigationPort)? {
        guard editorCommandsAreActionable else { return nil }
        return activeEditor as? any EditorNavigationPort
    }

    private var actionableDisplayOptions: (any EditorDisplayOptionsPort)? {
        guard editorCommandsAreActionable else { return nil }
        return activeEditor as? any EditorDisplayOptionsPort
    }

    private var actionableFoldingEditor: (any FoldingEditorPort)? {
        guard editorCommandsAreActionable,
              let editor = activeEditor as? any FoldingEditorPort,
              editor.supportsFolding else { return nil }
        return editor
    }

    private func closeScope(for action: Selector?) -> TabCloseScope? {
        switch action {
        case #selector(performCloseAllTabs(_:)): .all
        case #selector(performCloseOtherTabs(_:)): .others
        case #selector(performCloseTabsToLeft(_:)): .left
        case #selector(performCloseTabsToRight(_:)): .right
        case #selector(performCloseUnchangedTabs(_:)): .unchanged
        case #selector(performCloseUnpinnedTabs(_:)): .unpinned
        default: nil
        }
    }

    private var actionableEditorCommands: (any EditorCommandPort)? {
        guard editorCommandsAreActionable else { return nil }
        return activeEditor as? any EditorCommandPort
    }

    private var editorCommandsAreActionable: Bool {
        let snapshot = workspace.snapshot()
        return snapshot.startup == .ready
            && snapshot.activeBuffer != nil
            && !terminationReviewInProgress
    }

    private var workspaceInteractionsAreActionable: Bool {
        workspace.snapshot().startup == .ready && !terminationReviewInProgress
    }

    private var workspaceBrowserCommandsAreActionable: Bool {
        workspaceInteractionsAreActionable && workspaceBrowserUseCase?.acceptsCommands == true
    }

    private func navigateTabs(_ command: TabNavigationCommand) {
        guard workspaceInteractionsAreActionable else { return }
        Task { @MainActor [weak self] in
            guard let self, self.workspaceInteractionsAreActionable else { return }
            _ = await self.workspace.navigateTabs(command)
        }
    }

    private func moveActiveTab(by offset: Int) {
        guard workspaceInteractionsAreActionable else { return }
        Task { @MainActor [weak self] in
            guard let self, self.workspaceInteractionsAreActionable else { return }
            _ = await self.workspace.moveActiveTab(by: offset)
        }
    }

    private func performEditorCommand(_ command: EditorCommand) {
        guard let editor = actionableEditorCommands, editor.canPerform(command) else { return }
        editor.perform(command)
    }

    private func editorCommand(for action: Selector?) -> EditorCommand? {
        switch action {
        case #selector(performUndo(_:)): .undo
        case #selector(performRedo(_:)): .redo
        case #selector(performCut(_:)): .cut
        case #selector(performCopy(_:)): .copy
        case #selector(performPaste(_:)): .paste
        case #selector(performDelete(_:)): .delete
        case #selector(performSelectAll(_:)): .selectAll
        case #selector(performDuplicateLine(_:)): .duplicateLine
        case #selector(performMoveLineUp(_:)): .moveLineUp
        case #selector(performMoveLineDown(_:)): .moveLineDown
        case #selector(performDeleteLine(_:)): .deleteLine
        case #selector(performJoinLines(_:)): .joinLines
        case #selector(performUppercase(_:)): .uppercase
        case #selector(performLowercase(_:)): .lowercase
        case #selector(performIndent(_:)): .indent
        case #selector(performUnindent(_:)): .unindent
        case #selector(performTrimTrailingWhitespace(_:)): .trimTrailingWhitespace
        default: nil
        }
    }

    private var activeTextFileFormat: TextFileConversion {
        textFileFormat(for: workspace.activeFileContext())
    }

    private func textFileFormat(for context: FileWorkspaceContext?) -> TextFileConversion {
        guard let binding = context?.binding else {
            return TextFileConversion(
                encoding: .utf8,
                byteOrderMark: .absent,
                lineEnding: .none
            )
        }
        return TextFileConversion(
            encoding: binding.encoding,
            byteOrderMark: binding.byteOrderMark,
            lineEnding: binding.lineEnding
        )
    }

    private func fileEncodingChoice(
        for action: Selector?
    ) -> (encoding: TextFileEncoding, byteOrderMark: ByteOrderMark)? {
        switch action {
        case #selector(performConvertToUTF8(_:)): (.utf8, .absent)
        case #selector(performConvertToUTF8BOM(_:)): (.utf8, .present)
        case #selector(performConvertToUTF16LittleEndian(_:)): (.utf16LittleEndian, .present)
        case #selector(performConvertToUTF16LittleEndianWithoutBOM(_:)): (.utf16LittleEndian, .absent)
        case #selector(performConvertToUTF16BigEndian(_:)): (.utf16BigEndian, .present)
        case #selector(performConvertToUTF16BigEndianWithoutBOM(_:)): (.utf16BigEndian, .absent)
        default: nil
        }
    }

    private func fileLineEndingChoice(for action: Selector?) -> LineEnding? {
        switch action {
        case #selector(performConvertToLF(_:)): .lf
        case #selector(performConvertToCRLF(_:)): .crlf
        case #selector(performConvertToCR(_:)): .cr
        default: nil
        }
    }

    private func isOpenUsingEncodingAction(_ action: Selector?) -> Bool {
        switch action {
        case #selector(performOpenAsUTF8(_:)),
             #selector(performOpenAsUTF16LittleEndian(_:)),
             #selector(performOpenAsUTF16BigEndian(_:)):
            true
        default:
            false
        }
    }

    private func routeFileFormatConversion(
        encoding: TextFileEncoding? = nil,
        byteOrderMark: ByteOrderMark? = nil,
        lineEnding: LineEnding? = nil
    ) {
        guard workspaceInteractionsAreActionable, fileUseCase != nil,
              let context = workspace.activeFileContext() else { return }
        let current = textFileFormat(for: context)
        let conversion = TextFileConversion(
            encoding: encoding ?? current.encoding,
            byteOrderMark: byteOrderMark ?? current.byteOrderMark,
            lineEnding: lineEnding ?? current.lineEnding
        )
        guard conversion != current else { return }
        beginFileCommandTask { [weak self] in
            await self?.routeAcceptedSaveFile(
                conversion: conversion,
                expectedContext: context
            )
        }
    }

    public func routeOpenFile(encodingHint: TextFileEncoding? = nil) async {
        guard workspaceInteractionsAreActionable,
              fileUseCase != nil,
              let url = await filePanels?.chooseOpenURL(attachedTo: window),
              workspaceInteractionsAreActionable else { return }
        await handle(fileOutcome: await openDocumentURL(url, assuming: encodingHint)) { [weak self] in
            self?.beginFileCommandTask { [weak self] in
                await self?.routeOpenFile(encodingHint: encodingHint)
            }
        }
    }

    /// Finder/Open With and recent-document entry point. The entire batch is
    /// admitted as one window-owned task so termination waits for accepted I/O.
    public func openExternalURLs(
        _ urls: [URL],
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty, !terminationReviewInProgress, !hasTornDownWindow else {
            completion?(false)
            return
        }
        beginFileCommandTask { [weak self] in
            guard let self else {
                completion?(false)
                return
            }
            await self.waitForStartup()
            guard self.workspaceInteractionsAreActionable,
                  let fileUseCase = self.fileUseCase else {
                completion?(false)
                return
            }
            var succeeded = true
            let outcomes = await fileUseCase.open(fileURLs)
            for (url, outcome) in zip(fileURLs, outcomes) {
                guard !Task.isCancelled, !self.hasTornDownWindow else {
                    succeeded = false
                    break
                }
                switch outcome {
                case .opened(let tabID), .activatedExisting(let tabID):
                    self.recordOpenedDocumentURL(tabID: tabID, fallback: url)
                case .failed:
                    succeeded = false
                    await self.handle(fileOutcome: outcome) {}
                }
            }
            completion?(succeeded)
        }
    }

    private func openDocumentURL(
        _ url: URL,
        assuming encodingHint: TextFileEncoding? = nil
    ) async -> FileOpenOutcome {
        guard let fileUseCase else { return .failed(.noActiveDocument) }
        let outcome = await fileUseCase.open(url, assuming: encodingHint)
        switch outcome {
        case .opened(let tabID), .activatedExisting(let tabID):
            recordOpenedDocumentURL(tabID: tabID, fallback: url)
        case .failed:
            break
        }
        return outcome
    }

    private func recordOpenedDocumentURL(tabID: TabID, fallback: URL) {
        if let path = workspace.fileContext(tabID: tabID)?.binding?.canonicalPath {
            onDocumentURLUsed?(URL(fileURLWithPath: path))
        } else {
            onDocumentURLUsed?(fallback)
        }
    }

    private func routeAddWorkspaceRoot(_ url: URL) {
        guard workspaceBrowserCommandsAreActionable, let workspaceBrowserUseCase else { return }
        beginWorkspaceBrowserTask {
            guard !Task.isCancelled else { return }
            _ = await workspaceBrowserUseCase.addRoot(url)
        }
    }

    private func routeRemoveWorkspaceRoot(_ rootID: WorkspaceRootID) {
        guard workspaceBrowserCommandsAreActionable, let workspaceBrowserUseCase else { return }
        beginWorkspaceBrowserTask {
            guard !Task.isCancelled else { return }
            _ = await workspaceBrowserUseCase.removeRoot(rootID)
        }
    }

    private func routeLoadWorkspaceChildren(rootID: WorkspaceRootID, relativeDirectory: String) {
        guard workspaceBrowserCommandsAreActionable, let workspaceBrowserUseCase else { return }
        beginWorkspaceBrowserTask { [weak self] in
            do {
                let children = try await workspaceBrowserUseCase.children(
                    rootID: rootID,
                    relativeDirectory: relativeDirectory
                )
                guard let self, !Task.isCancelled else { return }
                self.workspaceSidebar.applyChildren(
                    rootID: rootID,
                    relativeDirectory: relativeDirectory,
                    entries: children
                )
            } catch let failure as WorkspaceBrowserFailure {
                guard let self, !Task.isCancelled else { return }
                self.workspaceSidebar.applyChildrenFailure(
                    rootID: rootID,
                    relativeDirectory: relativeDirectory,
                    failure: failure
                )
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.workspaceSidebar.applyChildrenFailure(
                    rootID: rootID,
                    relativeDirectory: relativeDirectory,
                    failure: .io(error.localizedDescription)
                )
            }
        }
    }

    func routeOpenWorkspaceEntry(_ entry: WorkspaceBrowserEntry) {
        guard workspaceBrowserCommandsAreActionable,
              let workspaceBrowserUseCase,
              let fileUseCase else { return }
        beginWorkspaceBrowserTask { [weak self] in
            do {
                let read = try await workspaceBrowserUseCase.readFile(entry)
                guard let self, self.workspaceInteractionsAreActionable, !Task.isCancelled else { return }
                self.beginAcceptedWorkspaceFileOpen(read, fileUseCase: fileUseCase)
            } catch let failure as WorkspaceBrowserFailure {
                guard let self, !Task.isCancelled else { return }
                self.workspaceSidebar.presentFailure(failure)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.workspaceSidebar.presentFailure(.io(error.localizedDescription))
            }
        }
    }

    private func beginAcceptedWorkspaceFileOpen(
        _ read: WorkspaceFileRead,
        fileUseCase: FileDocumentUseCase
    ) {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingWorkspaceFileOpenTasks.removeValue(forKey: token) }
            let outcome = await fileUseCase.open(read)
            guard !self.terminationReviewInProgress else { return }
            await self.handle(fileOutcome: outcome) {}
        }
        pendingWorkspaceFileOpenTasks[token] = task
    }

    private func routePersistWorkspaceNavigation(
        rootID: WorkspaceRootID,
        expanded: [String],
        selected: String?
    ) {
        guard workspaceBrowserCommandsAreActionable, let workspaceBrowserUseCase else { return }
        let revision = (workspaceNavigationRevisions[rootID] ?? 0) &+ 1
        workspaceNavigationRevisions[rootID] = revision
        beginWorkspaceBrowserTask { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled,
                  revision == self.workspaceNavigationRevisions[rootID] else { return }
            await workspaceBrowserUseCase.updateNavigation(
                rootID: rootID,
                expandedRelativePaths: expanded,
                selectedRelativePath: selected
            )
        }
    }

    private func beginWorkspaceBrowserTask(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.pendingWorkspaceBrowserTasks.removeValue(forKey: token)
        }
        pendingWorkspaceBrowserTasks[token] = task
    }

    private func cancelWorkspaceBrowserTasks() {
        filePanels?.cancelOutstandingPanels()
        let tasks = Array(pendingWorkspaceBrowserTasks.values)
        pendingWorkspaceBrowserTasks.removeAll()
        for task in tasks { task.cancel() }
    }

    private func beginFileCommandTask(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.pendingFileCommandTasks.removeValue(forKey: token) }
            await operation()
        }
        pendingFileCommandTasks[token] = task
    }

    public func routeSaveFile(
        conversion: TextFileConversion? = nil,
        expectedContext: FileWorkspaceContext? = nil
    ) async {
        await routeSaveFile(
            conversion: conversion,
            expectedContext: expectedContext,
            acceptedBeforeTermination: false
        )
    }

    private func routeAcceptedSaveFile(
        conversion: TextFileConversion? = nil,
        expectedContext: FileWorkspaceContext
    ) async {
        await routeSaveFile(
            conversion: conversion,
            expectedContext: expectedContext,
            acceptedBeforeTermination: true
        )
    }

    private func routeSaveFile(
        conversion: TextFileConversion?,
        expectedContext: FileWorkspaceContext?,
        acceptedBeforeTermination: Bool
    ) async {
        guard !hasTornDownWindow,
              workspaceInteractionsAreActionable || acceptedBeforeTermination,
              let fileUseCase,
              let context = expectedContext ?? workspace.activeFileContext(),
              workspace.activeFileContext() == context else { return }
        let outcome = await fileUseCase.saveActive(
            conversion: conversion,
            expectedContext: context
        )
        if case .requiresDestination = outcome {
            await routeSaveFileAs(
                conversion: conversion,
                expectedContext: context,
                acceptedBeforeTermination: acceptedBeforeTermination
            )
        } else {
            let resolved = await resolve(fileOutcome: outcome) { [weak self] in
                self?.beginFileCommandTask { [weak self] in
                    await self?.routeSaveFile(
                        conversion: conversion,
                        expectedContext: context,
                        acceptedBeforeTermination: true
                    )
                }
            }
            recordActiveDocumentURLIfSaved(resolved)
        }
    }

    public func routeSaveFileAs(
        conversion: TextFileConversion? = nil,
        expectedContext: FileWorkspaceContext? = nil
    ) async {
        await routeSaveFileAs(
            conversion: conversion,
            expectedContext: expectedContext,
            acceptedBeforeTermination: false
        )
    }

    private func routeAcceptedSaveFileAs(
        conversion: TextFileConversion? = nil,
        expectedContext: FileWorkspaceContext
    ) async {
        await routeSaveFileAs(
            conversion: conversion,
            expectedContext: expectedContext,
            acceptedBeforeTermination: true
        )
    }

    private func routeSaveFileAs(
        conversion: TextFileConversion?,
        expectedContext: FileWorkspaceContext?,
        acceptedBeforeTermination: Bool
    ) async {
        guard !hasTornDownWindow,
              workspaceInteractionsAreActionable || acceptedBeforeTermination,
              let fileUseCase,
              let context = expectedContext ?? workspace.activeFileContext(),
              workspace.activeFileContext() == context,
              let url = await filePanels?.chooseSaveURL(suggestedName: context.title, attachedTo: window),
              workspaceInteractionsAreActionable || acceptedBeforeTermination,
              !hasTornDownWindow,
              workspace.activeFileContext() == context else { return }
        let outcome = await resolve(fileOutcome: await fileUseCase.saveAs(
            url,
            conversion: conversion,
            expectedContext: context
        )) { [weak self] in
            self?.beginFileCommandTask { [weak self] in
                await self?.routeSaveFileAs(
                    conversion: conversion,
                    expectedContext: context,
                    acceptedBeforeTermination: true
                )
            }
        }
        recordActiveDocumentURLIfSaved(outcome)
    }

    private func routeSaveCopyAs(expectedContext: FileWorkspaceContext) async {
        guard !hasTornDownWindow,
              let fileUseCase,
              workspace.activeFileContext() == expectedContext,
              let url = await filePanels?.chooseSaveURL(
                suggestedName: expectedContext.title,
                attachedTo: window
              ),
              !hasTornDownWindow,
              workspace.activeFileContext() == expectedContext else { return }
        _ = await resolve(fileOutcome: await fileUseCase.saveCopy(
            url,
            expectedContext: expectedContext
        )) { [weak self] in
            self?.beginFileCommandTask { [weak self] in
                await self?.routeSaveCopyAs(expectedContext: expectedContext)
            }
        }
    }

    private func routeSaveAll() async {
        guard let fileUseCase else { return }
        let originalTabID = workspace.snapshot().tabs.first(where: \.isActive)?.id
        let dirtyTabIDs = workspace.snapshot().tabs.filter(\.isDirty).map(\.id)
        for tabID in dirtyTabIDs {
            guard !Task.isCancelled, !hasTornDownWindow,
                  workspace.snapshot().tabs.contains(where: { $0.id == tabID && $0.isDirty }) else {
                continue
            }
            if workspace.snapshot().tabs.first(where: \.isActive)?.id != tabID {
                guard case .applied = await workspace.activate(tabID: tabID) else { break }
            }
            guard let context = workspace.activeFileContext(), context.tabID == tabID else { break }
            var outcome = await fileUseCase.saveActive(expectedContext: context)
            if case .requiresDestination = outcome {
                guard let url = await filePanels?.chooseSaveURL(
                    suggestedName: context.title,
                    attachedTo: window
                ), !hasTornDownWindow, workspace.activeFileContext() == context else { break }
                outcome = await fileUseCase.saveAs(url, expectedContext: context)
            }
            let resolved = await resolve(fileOutcome: outcome) {}
            guard case .saved = resolved else { break }
            recordActiveDocumentURLIfSaved(resolved)
        }
        if let originalTabID,
           !hasTornDownWindow,
           workspace.snapshot().tabs.contains(where: { $0.id == originalTabID }),
           workspace.snapshot().tabs.first(where: \.isActive)?.id != originalTabID {
            _ = await workspace.activate(tabID: originalTabID)
        }
    }

    private func recordActiveDocumentURLIfSaved(_ outcome: FileSaveOutcome) {
        guard case .saved(let tabID) = outcome,
              let path = workspace.fileContext(tabID: tabID)?.binding?.canonicalPath else { return }
        onDocumentURLUsed?(URL(fileURLWithPath: path))
    }

    public var hasDirtyDocuments: Bool {
        workspace.snapshot().tabs.contains(where: \.isDirty)
    }

    public var requiresTerminationReview: Bool {
        hasDirtyDocuments || recoveryUseCase != nil || extensionUseCase != nil
            || !pendingFileCommandTasks.isEmpty
            || !pendingWorkspaceBrowserTasks.isEmpty || !pendingWorkspaceFileOpenTasks.isEmpty
    }

    @discardableResult
    public func flushRecovery(final: Bool = false) async -> Bool {
        guard let recoveryUseCase else { return true }
        let outcome = final
            ? await recoveryUseCase.flushForTermination()
            : await recoveryUseCase.flush()
        switch outcome {
        case .saved:
            return true
        case .failed(let error):
            let failure = PersistenceFailure(operation: .save, cause: error)
            errorPresenter.present(failure: failure) { [weak recoveryUseCase] in
                Task {
                    if final { _ = await recoveryUseCase?.flushForTermination() }
                    else { _ = await recoveryUseCase?.flush() }
                }
            }
            return false
        }
    }

    /// Shared red-close/Cmd-Q gate. Discard is remembered only for this review;
    /// a concurrently dirtied, previously saved tab is reviewed again.
    public func reviewDirtyDocumentsForTermination() async -> Bool {
        guard beginTerminationReviewAdmission() else { return false }
        return await performPreparedTerminationReview()
    }

    func beginTerminationReviewAdmission() -> Bool {
        guard !terminationReviewInProgress else { return false }
        terminationReviewInProgress = true
        documentIntelligenceTask?.cancel()
        documentIntelligenceTask = nil
        documentIntelligenceUseCase?.cancel()
        commandPalettePanel.dismiss()
        symbolOutlinePanel.dismiss()
        currentDocumentOutline = nil
        workspaceBrowserUseCase?.suspendCommands()
        workspaceRestoreTask?.cancel()
        workspaceRestoreTask = nil
        cancelWorkspaceBrowserTasks()
        updateWorkspaceInteractionAdmission(workspace.snapshot())
        cancelSearch()
        activeEditor.setInputEnabled(false)
        return true
    }

    func continuePreparedTerminationReview() async -> Bool {
        guard terminationReviewInProgress else { return false }
        return await performPreparedTerminationReview()
    }

    private func performPreparedTerminationReview() async -> Bool {
        var approved = false
        defer {
            if !approved {
                terminationReviewInProgress = false
                extensionUseCase?.resumeInvocations()
                Task { @MainActor [weak workspaceBrowserUseCase] in
                    await workspaceBrowserUseCase?.resumeCommandsAndReconcile()
                }
                let snapshot = workspace.snapshot()
                updateWorkspaceInteractionAdmission(snapshot)
                editorBinding.render(snapshot)
            }
        }
        await waitForAcceptedWorkspaceTasks()
        await extensionUseCase?.suspendInvocationsAndWait()
        guard dirtyDecisionPresenter != nil || !hasDirtyDocuments else { return false }
        let retrySaveTabID = terminationRetrySaveTabID
        terminationRetrySaveTabID = nil
        let outcome = await tabCloseCoordinator.reviewDirtyForTermination(
            saveAvailable: fileUseCase != nil,
            decision: { [weak self] tab, saveAvailable in
                if tab.id == retrySaveTabID { return .save }
                return await self?.closeDecision(for: tab, saveAvailable: saveAvailable) ?? .cancel
            },
            save: { [weak self] id, revision in
                await self?.saveBeforeClosing(
                    tabID: id,
                    expectedRevision: revision,
                    retryContext: .termination
                )
                    ?? .failed(PersistenceFailure(operation: .save, cause: .unavailable("window closed")))
            }
        )
        guard case .completed = outcome else {
            if case .failed(let failure) = outcome { presentCloseFailure(failure) }
            return false
        }
        approved = await flushRecovery(final: true)
        return approved
    }

    func cancelPreparedTerminationReview() {
        guard terminationReviewInProgress else { return }
        terminationReviewInProgress = false
        extensionUseCase?.resumeInvocations()
        Task { @MainActor [weak workspaceBrowserUseCase] in
            await workspaceBrowserUseCase?.resumeCommandsAndReconcile()
        }
        let snapshot = workspace.snapshot()
        updateWorkspaceInteractionAdmission(snapshot)
        editorBinding.render(snapshot)
    }

    private func waitForAcceptedWorkspaceTasks() async {
        while let task = pendingNewScratchTasks.values.first
            ?? pendingCloseTasks.values.first
            ?? pendingRestoreClosedTabTasks.values.first
            ?? pendingFolderActivationTasks.values.first
            ?? pendingFileCommandTasks.values.first
            ?? pendingWorkspaceFileOpenTasks.values.first
            ?? pendingWorkspaceBrowserTasks.values.first {
            await task.value
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if permitsNextWindowClose {
            permitsNextWindowClose = false
            return true
        }
        guard requiresTerminationReview else { return true }
        guard let terminationCoordinator else { return false }
        terminationCoordinator.requestWindowClose(windowController: self) { [weak self, weak sender] approved in
            guard let self else { return }
            guard approved, let sender else { return }
            self.permitsNextWindowClose = true
            self.approvedWindowClose(sender)
        }
        return false
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        onBecameKey?()
    }

    public func refreshAppearance() {
        appliedThemePalette = nil
        updateLanguageTheme()
    }

    public func windowWillClose(_ notification: Notification) {
        tearDownWindow()
    }

    public func windowDidResignKey(_ notification: Notification) {
        Task { [weak self] in _ = await self?.flushRecovery() }
    }

    private func configureStatusButton(
        _ button: NSButton,
        imageName: String,
        action: Selector,
        accessibilityIdentifier: String
    ) {
        button.target = self
        button.action = action
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        setStatus(button, text: button.title, warning: false)
    }

    private func setStatus(_ button: NSButton, text: String, warning: Bool) {
        let color: NSColor = warning ? .systemOrange : .secondaryLabelColor
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: color,
            ]
        )
        button.contentTintColor = color
        button.toolTip = text
        button.setAccessibilityLabel(text)
        if button === languageStatus { languageStatusIsWarning = warning }
        if button === extensionStatus { extensionStatusIsWarning = warning }
    }

    func makeLanguageStatusMenu() -> NSMenu {
        let menu = NSMenu(title: "Language")
        let automatic = menu.addItem(
            withTitle: "Automatic Detection",
            action: #selector(performAutomaticLanguage(_:)),
            keyEquivalent: ""
        )
        automatic.target = self
        let manuallySelectedID: LanguageID?
        switch languageState {
        case .ready(let detection, _):
            manuallySelectedID = detection.confidence == .manual ? detection.languageID : nil
            automatic.state = manuallySelectedID == nil ? .on : .off
        case .unavailableManual:
            manuallySelectedID = nil
            automatic.state = .off
        case .degraded:
            manuallySelectedID = nil
            automatic.state = .on
        }
        menu.addItem(.separator())
        var currentGroup: String?
        for definition in languageDefinitions {
            if definition.group != currentGroup {
                if currentGroup != nil { menu.addItem(.separator()) }
                let heading = NSMenuItem(title: definition.group, action: nil, keyEquivalent: "")
                heading.isEnabled = false
                menu.addItem(heading)
                currentGroup = definition.group
            }
            let item = menu.addItem(
                withTitle: definition.displayName,
                action: #selector(performChooseLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = definition.id.rawValue
            item.indentationLevel = 1
            item.state = manuallySelectedID == definition.id ? .on : .off
        }
        return menu
    }

    private func configureContent(
        injectedPresenter: (any PersistenceErrorPresenting)?
    ) -> any PersistenceErrorPresenting {
        let root = NSViewController()
        let dropView = FileDropView()
        dropView.onFiles = { [weak self] urls in
            self?.openExternalURLs(urls)
        }
        dropView.onEffectiveAppearanceChange = { [weak self] in
            self?.refreshAppearance()
        }
        root.view = dropView
        root.view.addSubview(persistenceBanner)
        root.view.addSubview(tabStrip)
        root.view.addSubview(searchPanel)
        workspaceContentSplit.isVertical = true
        workspaceContentSplit.dividerStyle = .thin
        workspaceContentSplit.translatesAutoresizingMaskIntoConstraints = false
        workspaceContentSplit.addArrangedSubview(editorHostView)
        workspaceSidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let preferredSidebarWidth = workspaceSidebar.widthAnchor.constraint(equalToConstant: 220)
        preferredSidebarWidth.priority = .defaultHigh
        preferredSidebarWidth.isActive = true
        workspaceSidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        root.view.addSubview(workspaceContentSplit)
        root.view.addSubview(statusBar)
        statusBar.setAccessibilityIdentifier("duckpad.status.bar")
        configureStatusButton(
            languageStatus,
            imageName: "chevron.left.forwardslash.chevron.right",
            action: #selector(performShowLanguageChooser(_:)),
            accessibilityIdentifier: "duckpad.language.status"
        )
        configureStatusButton(
            extensionStatus,
            imageName: "puzzlepiece.extension",
            action: #selector(performShowExtensions(_:)),
            accessibilityIdentifier: "duckpad.extensions.status"
        )
        configureStatusButton(
            symbolStatus,
            imageName: "list.bullet.indent",
            action: #selector(performShowDocumentSymbols(_:)),
            accessibilityIdentifier: "duckpad.symbols.status"
        )
        configureStatusButton(
            fileFormatStatus,
            imageName: "textformat",
            action: #selector(performShowFileFormatMenu(_:)),
            accessibilityIdentifier: "duckpad.file-format.status"
        )
        statusBar.addSubview(extensionStatus)
        statusBar.addSubview(symbolStatus)
        statusBar.addSubview(fileFormatStatus)
        statusBar.addSubview(languageStatus)
        NSLayoutConstraint.activate([
            persistenceBanner.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            persistenceBanner.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            persistenceBanner.topAnchor.constraint(equalTo: root.view.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: persistenceBanner.bottomAnchor),
            searchPanel.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            searchPanel.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            searchPanel.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            workspaceContentSplit.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            workspaceContentSplit.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            workspaceContentSplit.topAnchor.constraint(equalTo: searchPanel.bottomAnchor),
            workspaceContentSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            extensionStatus.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 6),
            extensionStatus.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            extensionStatus.heightAnchor.constraint(equalToConstant: 20),
            symbolStatus.leadingAnchor.constraint(equalTo: extensionStatus.trailingAnchor, constant: 8),
            symbolStatus.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            symbolStatus.heightAnchor.constraint(equalToConstant: 20),
            symbolStatus.trailingAnchor.constraint(lessThanOrEqualTo: fileFormatStatus.leadingAnchor, constant: -8),
            fileFormatStatus.trailingAnchor.constraint(equalTo: languageStatus.leadingAnchor, constant: -8),
            fileFormatStatus.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            fileFormatStatus.heightAnchor.constraint(equalToConstant: 20),
            languageStatus.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -6),
            languageStatus.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            languageStatus.heightAnchor.constraint(equalToConstant: 20),
            extensionStatus.trailingAnchor.constraint(lessThanOrEqualTo: languageStatus.leadingAnchor, constant: -12),
        ])
        window?.contentViewController = root
        return injectedPresenter ?? persistenceBanner
    }

    private func renderInitial(_ snapshot: WorkspaceSnapshot) {
        tabStrip.apply(tabs: snapshot.tabs)
        updateWorkspaceInteractionAdmission(snapshot)
        editorBinding.render(snapshot)
        updateWindowTitle(snapshot)
        renderFileFormatStatus()
    }

    private func renderWorkspaceBrowser(_ state: WorkspaceBrowserState) {
        switch state {
        case .idle, .loading:
            workspaceSidebar.setInteractionsEnabled(false)
        case .failed(let failure):
            let remainsUsable = workspaceBrowserUseCase?.acceptsCommands == true
            workspaceSidebar.setInteractionsEnabled(remainsUsable && workspaceInteractionsAreActionable)
            if remainsUsable { _ = workspaceSidebar.apply(roots: workspaceBrowserUseCase?.roots ?? []) }
            workspaceSidebar.presentFailure(failure)
        case .ready(let roots):
            workspaceSidebar.setInteractionsEnabled(workspaceInteractionsAreActionable)
            guard workspaceSidebar.apply(roots: roots) else { return }
            workspaceRestoreTask?.cancel()
            workspaceRestoreTask = Task { @MainActor [weak self] in
                guard let self, let useCase = self.workspaceBrowserUseCase else { return }
                for root in roots where root.isAvailable {
                    for path in root.expandedRelativePaths.sorted(by: { lhs, rhs in
                        let left = lhs.split(separator: "/").count
                        let right = rhs.split(separator: "/").count
                        return left == right ? lhs < rhs : left < right
                    }) {
                        guard !Task.isCancelled else { return }
                        do {
                            let children = try await useCase.children(rootID: root.id, relativeDirectory: path)
                            guard !Task.isCancelled else { return }
                            self.workspaceSidebar.applyChildren(
                                rootID: root.id,
                                relativeDirectory: path,
                                entries: children
                            )
                            self.workspaceSidebar.restoreNavigation(for: root)
                        } catch let failure as WorkspaceBrowserFailure {
                            self.workspaceSidebar.applyChildrenFailure(
                                rootID: root.id,
                                relativeDirectory: path,
                                failure: failure
                            )
                            break
                        } catch {
                            self.workspaceSidebar.applyChildrenFailure(
                                rootID: root.id,
                                relativeDirectory: path,
                                failure: .io(error.localizedDescription)
                            )
                            break
                        }
                    }
                    self.workspaceSidebar.restoreNavigation(for: root)
                }
            }
        }
    }

    private func handle(_ change: WorkspaceChange) {
        if shouldInvalidateDocumentIntelligence(for: change) {
            documentIntelligenceTask?.cancel()
            documentIntelligenceTask = nil
            if shouldCancelCompletion(for: change) { documentIntelligenceUseCase?.cancel() }
            symbolOutlinePanel.dismiss()
            currentDocumentOutline = nil
            setStatus(symbolStatus, text: "Symbols", warning: false)
            symbolStatus.setAccessibilityValue("Current document symbols")
        }
        tabStrip.apply(change: change)
        updateWorkspaceInteractionAdmission(change.snapshot)
        let firstLanguageValidation = change.snapshot.startup == .ready && !languageValidated
        var registryReady = true
        if firstLanguageValidation {
            languageValidated = true
            registryReady = languageUseCase?.validateRegistry() ?? false
        }
        editorBinding.render(change)
        if terminationReviewInProgress {
            activeEditor.setInputEnabled(false)
        }
        updateWindowTitle(change.snapshot)
        renderFileFormatStatus()
        recoveryUseCase?.workspaceDidChange(change)
        if change.snapshot.startup == .ready, case .bufferEdited = change.kind {
            languageDetectionTask?.cancel()
            languageDetectionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                _ = self?.languageUseCase?.refreshActive()
            }
        } else if change.snapshot.startup == .ready, shouldRefreshLanguage(for: change) {
            if firstLanguageValidation {
                if registryReady { _ = languageUseCase?.refreshActive() }
            } else { _ = languageUseCase?.refreshActive() }
        }
        updateLanguageTheme()
        guard let event = change.failureEvent, handledFailureIDs.insert(event.id).inserted else { return }
        errorPresenter.present(failure: event.failure) { [weak self] in
            guard let self else { return }
            Task { [weak workspace] in _ = await workspace?.retry(event.retry) }
        }
    }

    private func updateWorkspaceInteractionAdmission(_ snapshot: WorkspaceSnapshot) {
        let enabled = snapshot.startup == .ready && !terminationReviewInProgress
        tabStrip.setInteractionsEnabled(enabled)
        workspaceSidebar.setInteractionsEnabled(enabled && workspaceBrowserUseCase?.acceptsCommands == true)
        languageStatus.isEnabled = enabled
        symbolStatus.isEnabled = enabled && documentIntelligenceUseCase != nil
        fileFormatStatus.isEnabled = enabled && fileUseCase != nil
        extensionStatus.isEnabled = enabled
    }

    private func shouldRefreshLanguage(for change: WorkspaceChange) -> Bool {
        switch change.kind {
        case .reset, .tabInserted, .activeTabChanged, .tabRemovalPending, .tabRemoved:
            return true
        case .tabUpdated(let index):
            return change.snapshot.tabs.indices.contains(index) && change.snapshot.tabs[index].isActive
        case .bufferEdited, .persistence, .tabsReordered:
            return false
        }
    }

    private func shouldInvalidateDocumentIntelligence(for change: WorkspaceChange) -> Bool {
        switch change.kind {
        case .bufferEdited, .reset, .tabInserted, .activeTabChanged, .tabRemovalPending, .tabRemoved:
            return true
        case .tabUpdated(let index):
            return change.snapshot.tabs.indices.contains(index) && change.snapshot.tabs[index].isActive
        case .persistence, .tabsReordered:
            return false
        }
    }

    private func shouldCancelCompletion(for change: WorkspaceChange) -> Bool {
        switch change.kind {
        case .reset, .tabInserted, .activeTabChanged, .tabRemovalPending, .tabRemoved:
            return true
        case .bufferEdited, .tabUpdated, .persistence, .tabsReordered:
            return false
        }
    }

    private func presentRecoveryStartupFailure(_ failure: PersistenceFailure) {
        errorPresenter.present(failure: failure) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let recoveryUseCase = self.recoveryUseCase else { return }
                let outcome = await recoveryUseCase.discardFailedRecoveryAndStart()
                if case .failed(let retryFailure) = outcome {
                    self.presentRecoveryStartupFailure(retryFailure)
                }
            }
        }
    }

    private func requestClose(
        tabIDs: [TabID],
        retryingSaveTabID: TabID?,
        forcedDecision: CloseDecision? = nil
    ) async {
        let outcome = await tabCloseCoordinator.close(
            tabIDs: tabIDs,
            saveAvailable: fileUseCase != nil,
            decision: { [weak self] tab, saveAvailable in
                if tab.id == retryingSaveTabID { return .save }
                if let forcedDecision { return forcedDecision }
                return await self?.closeDecision(for: tab, saveAvailable: saveAvailable) ?? .cancel
            },
            save: { [weak self] id, revision in
                await self?.saveBeforeClosing(
                    tabID: id,
                    expectedRevision: revision,
                    retryContext: .tabs(tabIDs)
                )
                    ?? .failed(PersistenceFailure(operation: .save, cause: .unavailable("window closed")))
            }
        )
        await fileUseCase?.releaseSecurityScopedAccessForClosedDocuments()
        if case .completed = outcome { activeEditor.focus() }
        if case .failed(let failure) = outcome { presentCloseFailure(failure) }
    }

    private func closeDecision(for tab: TabSnapshot, saveAvailable: Bool) async -> CloseDecision {
        if let dirtyDecisionPresenter {
            return await dirtyDecisionPresenter.decision(
                for: tab,
                saveAvailable: saveAvailable,
                attachedTo: window
            )
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to \(tab.title) before closing?"
        alert.informativeText = "Discard closes this exact reviewed revision without writing."
        if saveAvailable { alert.addButton(withTitle: "Save") }
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        let response = alert.runModal()
        if saveAvailable, response == .alertFirstButtonReturn { return .save }
        let discardResponse: NSApplication.ModalResponse = saveAvailable ? .alertThirdButtonReturn : .alertSecondButtonReturn
        return response == discardResponse ? .discard : .cancel
    }

    private func presentCloseFailure(_ failure: PersistenceFailure) {
        errorPresenter.present(failure: failure) {}
    }

    private func performMove(_ tabID: TabID, to index: Int) {
        guard workspaceInteractionsAreActionable else { return }
        Task { @MainActor [weak self] in
            guard let self, self.workspaceInteractionsAreActionable else { return }
            _ = await self.workspace.moveTab(tabID, to: index)
        }
    }

    private func performContextAction(_ action: TabContextAction, for tabID: TabID) {
        guard workspaceInteractionsAreActionable else { return }
        switch action {
        case .close(let scope):
            performClose(scope: scope, relativeTo: tabID)
        case .setPinned(let pinned):
            Task { @MainActor [weak self] in
                guard let self, self.workspaceInteractionsAreActionable else { return }
                _ = await self.workspace.setPinned(tabID, isPinned: pinned)
            }
        case .copyFullPath:
            guard let path = workspace.snapshot().tabs.first(where: { $0.id == tabID })?.fullPath else { return }
            pathActionHandler.copyFullPath(path)
        case .openContainingFolder:
            guard let path = workspace.snapshot().tabs.first(where: { $0.id == tabID })?.fullPath else { return }
            pathActionHandler.openContainingFolder(for: path)
        }
    }

    private func routeFind(_ query: SearchQuery) {
        guard workspaceInteractionsAreActionable,
              !query.pattern.isEmpty, let searchUseCase else { return }
        let operation = beginSearchOperation()
        searchPanel.presentStatus("Searching…")
        searchTask = Task { [weak self] in
            do {
                let match = try await searchUseCase.find(query)
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(match == nil ? "No matches" : "Match selected")
            } catch SearchFailure.cancelled { }
            catch SearchFailure.noSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Select a non-empty range to search")
            }
            catch SearchFailure.invalidSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Selection changed; select a range again")
            }
            catch {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Search failed: \(error)")
            }
        }
    }

    private func routeFindAll(_ query: SearchQuery, incremental: Bool = false) {
        guard workspaceInteractionsAreActionable,
              !query.pattern.isEmpty, let searchUseCase else { return }
        let operation = beginSearchOperation()
        searchPanel.presentStatus("Searching…")
        searchTask = Task { [weak self] in
            do {
                let result = try await searchUseCase.findAll(query)
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.present(result)
            } catch SearchFailure.cancelled { }
            catch SearchFailure.noSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Select a non-empty range to search")
            }
            catch SearchFailure.invalidSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Selection changed; select a range again")
            }
            catch {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Search failed: \(error)")
            }
        }
    }

    private func routeFindInFolder(_ query: SearchQuery) {
        guard workspaceInteractionsAreActionable,
              !query.pattern.isEmpty,
              let folderSearchUseCase,
              let filePanels else { return }
        let operation = beginSearchOperation()
        searchPanel.presentStatus("Choose a folder…")
        searchTask = Task { [weak self] in
            guard let self,
                  let root = await filePanels.chooseFolderURL(attachedTo: self.window),
                  self.searchOperationID == operation,
                  self.workspaceInteractionsAreActionable else { return }
            self.searchPanel.presentStatus("Searching \(root.lastPathComponent)…")
            do {
                let result = try await folderSearchUseCase.search(rootPath: root.path, query: query)
                guard self.searchOperationID == operation else { return }
                self.searchPanel.present(result)
            } catch FolderSearchFailure.search(.cancelled) { }
            catch {
                guard self.searchOperationID == operation else { return }
                self.searchPanel.presentStatus("Folder search failed: \(error)")
            }
        }
    }

    private func routeReplace(_ query: SearchQuery) {
        guard workspaceInteractionsAreActionable,
              !query.pattern.isEmpty, let searchUseCase else { return }
        let operation = beginSearchOperation()
        searchTask = Task { [weak self] in
            do {
                let next = try await searchUseCase.replaceCurrentThenFind(query)
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(next == nil ? "Replaced; no next match" : "Replaced")
            } catch SearchFailure.noSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Select a non-empty range to replace")
            }
            catch SearchFailure.invalidSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Selection changed; select a range again")
            }
            catch {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Replace failed: \(error)")
            }
        }
    }

    private func routeReplaceAll(_ query: SearchQuery) {
        guard workspaceInteractionsAreActionable,
              !query.pattern.isEmpty, let searchUseCase else { return }
        let operation = beginSearchOperation()
        searchTask = Task { [weak self] in
            do {
                let count = try await searchUseCase.replaceAll(query)
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Replaced \(count) match(es)")
            } catch SearchFailure.noSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Select a non-empty range to replace")
            }
            catch SearchFailure.invalidSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Selection changed; select a range again")
            }
            catch {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Replace All failed: \(error)")
            }
        }
    }

    private func routeActivateSearchMatch(_ match: SearchMatch) {
        guard workspaceInteractionsAreActionable, let searchUseCase else { return }
        let operation = beginSearchOperation()
        searchTask = Task { [weak self] in
            do {
                try await searchUseCase.activate(match)
                guard self?.searchOperationID == operation else { return }
                self?.activeEditor.focus()
            } catch {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus("Result is stale")
            }
        }
    }

    func routeActivateFolderSearchMatch(
        document: FolderSearchDocumentResult,
        match: FolderSearchMatch
    ) {
        guard workspaceInteractionsAreActionable,
              let fileUseCase else { return }
        let operation = beginSearchOperation()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingFolderActivationTasks.removeValue(forKey: token) }
            let outcome = await fileUseCase.activateFolderSearchMatch(document: document, match: match)
            guard self.searchOperationID == operation,
                  self.workspaceInteractionsAreActionable else { return }
            switch outcome {
            case .activated:
                self.searchPanel.presentStatus("Opened \(document.relativePath):\(match.line)")
            case .stale:
                self.searchPanel.presentStatus("Folder result changed; search again")
            case .failed(let failure):
                guard failure != .cancelled else { return }
                self.fileConflictPresenter?.presentFileFailure(
                    failure,
                    attachedTo: self.window,
                    retry: { [weak self] in
                        self?.routeActivateFolderSearchMatch(document: document, match: match)
                    }
                )
            }
        }
        pendingFolderActivationTasks[token] = task
        searchTask = task
    }

    private func beginSearchOperation() -> UInt64 {
        searchTask?.cancel()
        searchOperationID &+= 1
        return searchOperationID
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchOperationID &+= 1
    }

    private func closeSearchPanel() {
        cancelSearch()
        searchPanel.hide()
        activeEditor.focus()
    }

    private func handle(
        fileOutcome: FileOpenOutcome,
        retry: @escaping @MainActor () -> Void
    ) async {
        if case .failed(.workspace) = fileOutcome { return }
        if case .failed(let failure) = fileOutcome {
            fileConflictPresenter?.presentFileFailure(failure, attachedTo: window, retry: retry)
        }
    }

    @discardableResult
    private func resolve(
        fileOutcome: FileSaveOutcome,
        retry: @escaping @MainActor () -> Void
    ) async -> FileSaveOutcome {
        var current = fileOutcome
        while true {
            switch current {
            case .conflict:
                guard let fileUseCase, let presenter = fileConflictPresenter else { return current }
                let resolution = await presenter.resolveExternalConflict(attachedTo: window)
                if resolution == .compare {
                    switch await fileUseCase.pendingExternalComparison() {
                    case .ready(let comparison):
                        await presenter.presentExternalComparison(comparison, attachedTo: window)
                        continue
                    case .failed(let failure):
                        presenter.presentFileFailure(failure, attachedTo: window, retry: retry)
                        return .failed(failure)
                    }
                }
                current = await fileUseCase.resolveConflict(resolution)
            case .failed(.workspace):
                return current
            case .failed(let failure):
                fileConflictPresenter?.presentFileFailure(failure, attachedTo: window, retry: retry)
                return current
            case .saved, .requiresDestination, .cancelled:
                return current
            }
        }
    }

    private func saveBeforeClosing(
        tabID: TabID,
        expectedRevision: UInt64,
        retryContext: CloseRetryContext
    ) async -> TabCloseSaveOutcome {
        guard let reviewed = workspace.snapshot().tabs.first(where: { $0.id == tabID }) else {
            return .cancelled
        }
        guard reviewed.buffer.revision == expectedRevision else {
            return .reviewStale(currentRevision: reviewed.buffer.revision)
        }
        guard let fileUseCase else {
            return .failed(PersistenceFailure(operation: .save, cause: .unavailable("file save unavailable")))
        }
        if workspace.snapshot().tabs.first(where: \.isActive)?.id != tabID {
            switch await workspace.activate(tabID: tabID) {
            case .applied:
                break
            case .persistenceFailed(let failure):
                return .workspaceFailure(failure)
            case .rejected(let error):
                return .failed(PersistenceFailure(
                    operation: .save,
                    cause: .corrupt("close-save activation rejected: \(error)")
                ))
            }
        }
        var outcome = await fileUseCase.saveActive()
        if case .requiresDestination = outcome {
            guard let context = workspace.activeFileContext(),
                  let url = await filePanels?.chooseSaveURL(suggestedName: context.title, attachedTo: window) else {
                return .cancelled
            }
            outcome = await fileUseCase.saveAs(url)
        }
        if case .failed(.workspace(let failure)) = outcome { return .workspaceFailure(failure) }
        let resolved = await resolve(fileOutcome: outcome) { [weak self] in
            guard let self else { return }
            self.retryClose(retryContext, failedSaveTabID: tabID)
        }
        switch resolved {
        case .saved:
            return .saved
        case .cancelled, .requiresDestination, .conflict:
            return .cancelled
        case .failed(.workspace(let failure)):
            return .workspaceFailure(failure)
        case .failed(let failure):
            if fileConflictPresenter != nil { return .alreadyPresented }
            return .failed(PersistenceFailure(
                operation: .save,
                cause: .unavailable("file save failed: \(failure)")
            ))
        }
    }

    private func retryClose(_ context: CloseRetryContext, failedSaveTabID: TabID) {
        switch context {
        case .tabs(let tabIDs):
            Task { @MainActor [weak self] in
                await self?.requestClose(tabIDs: tabIDs, retryingSaveTabID: failedSaveTabID)
            }
        case .termination:
            terminationRetrySaveTabID = failedSaveTabID
            terminationCoordinator?.retryApplicationTermination()
        }
    }

    private func updateWindowTitle(_ snapshot: WorkspaceSnapshot) {
        guard let active = snapshot.tabs.first(where: \.isActive) else {
            window?.title = "Duckpad"
            window?.isDocumentEdited = false
            return
        }
        window?.title = "\(active.title) — Duckpad"
        window?.isDocumentEdited = active.isDirty
    }

    private func renderFileFormatStatus() {
        let format = activeTextFileFormat
        let hasFileBinding = workspace.activeFileContext()?.binding != nil
        let encoding: String
        switch format.encoding {
        case .utf8:
            encoding = format.byteOrderMark == .present ? "UTF-8 BOM" : "UTF-8"
        case .utf16LittleEndian:
            encoding = format.byteOrderMark == .present ? "UTF-16 LE BOM" : "UTF-16 LE"
        case .utf16BigEndian:
            encoding = format.byteOrderMark == .present ? "UTF-16 BE BOM" : "UTF-16 BE"
        }
        let ending: String
        switch format.lineEnding {
        case .none where !hasFileBinding: ending = "Unsaved"
        case .none: ending = "No EOL"
        case .lf: ending = "LF"
        case .crlf: ending = "CRLF"
        case .cr: ending = "CR"
        case .mixed: ending = "Mixed EOL"
        }
        setStatus(fileFormatStatus, text: "\(encoding) · \(ending)", warning: false)
        fileFormatStatus.toolTip = "Encoding: \(encoding); line endings: \(ending). Choose to convert and save."
        fileFormatStatus.setAccessibilityValue("\(encoding), \(ending)")
    }

    private func renderLanguageState(_ state: LanguageServiceState) {
        languageState = state
        switch state {
        case .ready(let detection, let fallback):
            let name = languageUseCase?.registry[detection.languageID]?.displayName ?? detection.languageID.rawValue
            let tier = languageUseCase?.registry[detection.languageID]?.supportTier
            let suffix = tier == .structural ? " · structural" : ""
            setStatus(
                languageStatus,
                text: fallback ? "\(name) · styling paused (large file)" : name + suffix,
                warning: false
            )
        case .unavailableManual(let requestedID, let fallbackID):
            let fallbackName = languageUseCase?.registry[fallbackID]?.displayName ?? fallbackID.rawValue
            setStatus(
                languageStatus,
                text: "Unavailable language: \(requestedID.rawValue) · using \(fallbackName)",
                warning: true
            )
        case .degraded(let reason):
            setStatus(languageStatus, text: "Plain Text · \(reason)", warning: true)
        }
    }

    private func updateLanguageTheme() {
        guard let appearance = window?.effectiveAppearance else { return }
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let palette: EditorThemePalette = highContrast
            ? (dark ? .highContrastDark : .highContrastLight)
            : (dark ? .dark : .light)
        guard palette != appliedThemePalette else { return }
        appliedThemePalette = palette
        languageUseCase?.applyTheme(palette)
    }

    private func renderExtensionState(_ state: ExtensionRegistryState) {
        extensionState = state; extensionsPanel.render(state)
        let enabled = state.items.filter(\.enabled).count
        if !state.discoveryFailures.isEmpty {
            setStatus(
                extensionStatus,
                text: "Extensions: \(enabled) enabled · \(state.discoveryFailures.count) issue(s)",
                warning: true
            )
        } else {
            setStatus(
                extensionStatus,
                text: state.operationStatus ?? "Extensions: \(enabled) enabled",
                warning: false
            )
        }
        onExtensionCommandsChanged?()
    }

    private func renderExtensionError(_ error: any Error) {
        setStatus(extensionStatus, text: "Extension error: \(error)", warning: true)
    }

    private func reviewCapabilities(for item: ExtensionRegistryItem, allow: Bool) {
        guard let window else { return }
        if !allow, item.issue == .untrustedPublisher {
            let alert = NSAlert(); alert.messageText = "Reset publisher revocation?"
            alert.informativeText = "This removes the durable publisher tombstone for \(item.manifest.publisher.id) (\(item.publisherFingerprint)). The extension remains disabled and receives no access until you explicitly enable it and approve a new identity-bound capability review."
            alert.addButton(withTitle: "Reset Revocation"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                Task { @MainActor [weak self] in
                    do { try await self?.extensionUseCase?.resetPublisherRevocation(for: item.manifest.id) }
                    catch { self?.renderExtensionError(error) }
                }
            }
            return
        }
        let revocationToken: ExtensionRevocationReviewToken?
        if !allow {
            do { revocationToken = try extensionUseCase?.revocationReviewToken(for: item.manifest.id) }
            catch { renderExtensionError(error); return }
        } else { revocationToken = nil }
        let token: ExtensionConsentReviewToken?
        if allow {
            do { token = try extensionUseCase?.consentReviewToken(for: item.manifest.id) }
            catch { renderExtensionError(error); return }
        } else { token = nil }
        let alert = NSAlert()
        alert.messageText = allow
            ? "Grant capabilities to \(item.manifest.name)?"
            : "Revoke publisher \(item.manifest.publisher.id) across \(revocationToken?.affectedPackageIdentities.count ?? 0) extension(s)?"
        alert.informativeText = extensionReviewDisclosure(for: item.manifest.id, revoking: !allow) ?? "Extension identity unavailable; cancel and refresh."
        alert.addButton(withTitle: allow ? "Grant Exact Capabilities" : "Revoke Publisher")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor [weak self] in
                do {
                    if allow, let token {
                        try await self?.extensionUseCase?.grantReviewed(token, choices: token.requests)
                    } else if let revocationToken {
                        try await self?.extensionUseCase?.revokePublisher(revocationToken)
                    }
                } catch { self?.renderExtensionError(error) }
            }
        }
    }
}
