import DuckpadLocalization
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
final class FileDropView: NSView {
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
        guard sender.draggingSourceOperationMask.contains(.copy) else { return [] }
        let content = partition(fileURLs(from: sender))
        return (onFiles != nil && !content.files.isEmpty)
            || (onFolders != nil && !content.folders.isEmpty) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !draggingEntered(sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard prepareForDragOperation(sender) else { return false }
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
    private var displayedFailure: PersistenceFailure?
    private let retryButton = NSButton(title: L10n.text("Retry"), target: nil, action: nil)
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
        displayedFailure = failure
        message.stringValue = L10n.text("Session %1$@ failed: %2$@", L10n.text(failure.operation == .load ? "Restore" : "Save"), PresentationErrorText.message(failure.cause))
        retryAction = retry
        heightConstraint.constant = 36
        isHidden = false
    }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        retryButton.title = catalog.text("Retry")
        if let failure = displayedFailure {
            message.stringValue = catalog.text("Session %1$@ failed: %2$@", arguments: [
                catalog.text(failure.operation == .load ? "Restore" : "Save"),
                PresentationErrorText.message(failure.cause, catalog: catalog)
            ])
        }
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
    let editorGroupWorkspace: EditorGroupWorkspaceView
    private let editorGroupLayout = EditorGroupLayoutModel()
    private var provisionalEditorGroupLayout: EditorGroupLayoutSnapshot?
    var editorGroupLayoutSnapshot: EditorGroupLayoutSnapshot {
        provisionalEditorGroupLayout ?? editorGroupLayout.snapshot
    }
    var tabStrip: MultilineTabStripView { editorGroupWorkspace.primaryPane.tabStrip }
    private let fallbackEditor: TextViewEditorAdapter?
    var editor: TextViewEditorAdapter {
        precondition(fallbackEditor != nil, "NSTextView adapter is not active in production composition")
        return fallbackEditor!
    }
    private let activeEditor: any EditorPort
    private let editorGroupRouter: (any EditorGroupRoutingPort)?
    let searchPanel = SearchPanelView(frame: .zero)
    private lazy var searchWindowController = SearchWindowController(searchView: searchPanel)
    let liveFileBanner = LiveFileChangeBanner(frame: .zero)
    let commandBar = WindowCommandBarView(frame: .zero)
    private var statusBarHeightConstraint: NSLayoutConstraint!
    private var appPreferences = AppSettings.defaults
    let statusBar = DocumentStatusBarView(frame: .zero)
    private let persistenceBanner = PersistenceErrorBanner(frame: .zero)
    private let languageStatus = StatusBarButton(title: L10n.text("Plain Text"), target: nil, action: nil)
    private let symbolStatus = NSButton(title: L10n.text("Symbols"), target: nil, action: nil)
    private let fileFormatStatus = StatusBarButton(title: "UTF-8", target: nil, action: nil)
    private let extensionStatus = NSButton(title: L10n.text("Extensions loading…"), target: nil, action: nil)
    private let extensionsPanel = ExtensionsManagerPanel()
    let commandPalettePanel = CommandPalettePanel()
    let symbolOutlinePanel = SymbolOutlinePanel()
    private let workspaceSidebar = WorkspaceSidebarView(frame: .zero)
    private let workspaceContentSplit = NSSplitView(frame: .zero)
    private var highlightedSearch: (buffer: EditorBufferDescriptor, query: SearchQuery)?
    private var searchHighlightBuffer: EditorBufferDescriptor?
    private var searchUseCase: SearchWorkspaceUseCase?
    private let folderSearchUseCase: FolderSearchUseCase?
    private var languageUseCase: LanguageWorkspaceUseCase?
    private let documentIntelligenceUseCase: DocumentIntelligenceUseCase?
    private var extensionUseCase: ExtensionWorkspaceUseCase?
    private var workspaceBrowserUseCase: WorkspaceBrowserUseCase?
    private var extensionState = ExtensionRegistryState(items: [])
    private var displayedExtensionError: (any Error)?
    private var symbolPause: (title: String, amount: String, help: String, limit: String)?
    private var hasTornDownWindow = false
    private let framePersistence: WindowFramePersistence?
    private var hasPreparedWindowFrame = false
    public var onExtensionCommandsChanged: (() -> Void)?
    public var onNewWindowRequested: (() -> Void)?
    public var onSettingsRequested: (() -> Void)?
    public var onThemeRequested: ((AppAppearanceMode) -> Void)?
    public var currentAppearanceMode: (() -> AppAppearanceMode)?
    public var onBecameKey: (() -> Void)?
    public var onClosed: (() -> Void)?
    public var onDocumentURLUsed: ((URL) -> Void)?
    private let editorHostView: NSView
    private let fileUseCase: FileDocumentUseCase?
    private let filePanels: (any FilePanelPresenting)?
    private let fileConflictPresenter: (any FileConflictPresenting)?
    private let openDocumentComparePresenter: any OpenDocumentComparePresenting
    private let openDocumentComparisonUseCase: OpenDocumentComparisonUseCase
    private let dirtyDecisionPresenter: (any DirtyDocumentDecisionPresenting)?
    private let pathActionHandler: any TabPathActionHandling
    private let navigationPresenter: any EditorNavigationPresenting
    private let recoveryUseCase: SessionRecoveryUseCase?
    private let tabCloseCoordinator: TabCloseCoordinator
    let terminationCoordinator: ApplicationTerminationCoordinator?
    private let approvedWindowClose: @MainActor (NSWindow) -> Void
    private let keepsClosedWindowForReopen: Bool
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
    private var pendingWorkspaceFileReads: [UUID: FileLoadingProgress] = [:]
    private var editorGroupActivationTask: Task<Void, Never>?
    private var openDocumentCompareTask: Task<Void, Never>?
    private var openDocumentCompareGeneration: UInt64 = 0
    private var openDocumentCompareRevisions: [TabID: UInt64] = [:]
    private var openDocumentCompareFocusGeneration: UInt64?
    private var requestedEditorGroupSelection: (tabID: TabID, group: EditorGroupID)?
    private var latestWorkspaceSnapshot: WorkspaceSnapshot?
    private var editorGroupTabIndices: [EditorGroupID: [TabID: Int]] = [:]
    private var workspaceTabIndices: [TabID: Int] = [:]
    private(set) var editorGroupIncrementalLookupCount = 0
    private(set) var editorGroupIndexRebuildCount = 0
    private(set) var editorGroupReconcileCount = 0
    private(set) var editorGroupReconcileTabInspectionCount = 0
    private(set) var editorGroupCachedTabLookupCount = 0
    private(set) var editorGroupLinearTabInspectionCount = 0
    private var workspaceRestoreTask: Task<Void, Never>?
    private var workspaceNavigationRevisions: [WorkspaceRootID: UInt64] = [:]
    private var accessibilityDisplayObserver: WorkspaceNotificationObservation?

    public init(
        workspace: ScratchWorkspaceUseCase,
        editorAdapter: (any EditorPort)? = nil,
        editorView: NSView? = nil,
        secondaryEditorView: NSView? = nil,
        additionalEditorViews: [EditorGroupID: NSView] = [:],
        additionalEditorViewProvider: ((EditorGroupID) -> NSView)? = nil,
        editorGroupRouter: (any EditorGroupRoutingPort)? = nil,
        errorPresenter: (any PersistenceErrorPresenting)? = nil,
        fileUseCase: FileDocumentUseCase? = nil,
        filePanels: (any FilePanelPresenting)? = nil,
        fileConflictPresenter: (any FileConflictPresenting)? = nil,
        openDocumentComparePresenter: (any OpenDocumentComparePresenting)? = nil,
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
        framePersistence: WindowFramePersistence? = nil,
        automaticallyStarts: Bool = true
    ) {
        self.workspace = workspace
        self.framePersistence = framePersistence
        let fallback = editorAdapter == nil ? TextViewEditorAdapter() : nil
        precondition(
            (editorAdapter == nil) == (editorView == nil),
            "an injected editor port and view must be supplied together"
        )
        precondition(
            (secondaryEditorView == nil) == (editorGroupRouter == nil),
            "editor-group routing and its secondary view must be supplied together"
        )
        precondition(
            editorGroupRouter == nil || editorAdapter != nil,
            "editor-group routing requires the injected editor adapter"
        )
        if let editorAdapter, let editorGroupRouter {
            precondition(
                editorAdapter === editorGroupRouter,
                "editor-group routing must use the injected editor adapter"
            )
        }
        fallbackEditor = fallback
        activeEditor = editorAdapter ?? fallback!
        self.editorGroupRouter = editorGroupRouter
        editorHostView = editorView ?? fallback!.scrollView
        editorGroupWorkspace = EditorGroupWorkspaceView(
            primaryEditorHost: editorView ?? fallback!.scrollView,
            secondaryEditorHost: secondaryEditorView ?? NSView(),
            additionalEditorHosts: additionalEditorViews
        )
        editorGroupWorkspace.additionalEditorHostProvider = additionalEditorViewProvider
        self.fileUseCase = fileUseCase
        self.filePanels = filePanels
        self.fileConflictPresenter = fileConflictPresenter
        self.openDocumentComparePresenter = openDocumentComparePresenter
            ?? (fileConflictPresenter as? any OpenDocumentComparePresenting)
            ?? NativeOpenDocumentComparePresenter()
        openDocumentComparisonUseCase = OpenDocumentComparisonUseCase(
            workspace: workspace,
            editor: editorAdapter ?? fallback!
        )
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
        self.keepsClosedWindowForReopen = recoveryUseCase != nil && approvedWindowClose == nil
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
        (filePanels as? NativeFilePanelAdapter)?.preferredFileDirectory = { [weak self] in
            guard let self, self.appPreferences.fileDialogFollowsDocument,
                  let path = self.workspace.activeFileContext()?.binding?.canonicalPath else { return nil }
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }
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
        if let statusEditor = activeEditor as? any EditorStatusReportingPort {
            statusEditor.onEditorStatusChange = { [weak self] in self?.renderEditorStatus() }
        }
        if let foldingEditor = activeEditor as? any FoldingEditorPort {
            foldingEditor.onFoldStateChange = { [weak recoveryUseCase] in
                recoveryUseCase?.editorViewStateDidChange()
            }
        }
        editorGroupWorkspace.onAction = { [weak self] action in self?.performEditorGroupAction(action) }
        bindEditorGroupContextValidation()
        editorGroupRouter?.onEditorGroupFocus = { [weak self] group in
            self?.performEditorGroupFocus(group)
        }
        searchPanel.onFind = { [weak self] query in self?.routeFind(query) }
        searchPanel.onReplace = { [weak self] query in self?.routeReplace(query) }
        searchPanel.onReplaceAll = { [weak self] query in self?.routeReplaceAll(query) }
        searchPanel.onFindAll = { [weak self] query in self?.routeFindAll(query) }
        searchPanel.onMarkAll = { [weak self] query, clearPrevious in self?.routeBookmarkMatches(query, clearPrevious: clearPrevious) }
        searchPanel.onClearBookmarks = { [weak self] in
            self?.cancelSearch()
            self?.performClearBookmarks()
            self?.searchPanel.presentStatus(key: "Bookmarks cleared")
        }
        searchPanel.onChooseFolder = { [weak self] in self?.chooseSearchFolder() }
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
        if !((framePersistence?.restore(window)) ?? false) { window.center() }
        hasPreparedWindowFrame = true
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
        editorGroupActivationTask?.cancel()
        openDocumentCompareTask?.cancel()
    }

    public override func close() {
        guard !hasTornDownWindow else { return }
        saveWindowFrame()
        window?.delegate = nil
        super.close()
        tearDownWindow()
    }

    private func tearDownWindow() {
        guard !hasTornDownWindow else { return }
        hasTornDownWindow = true
        cancelSearch()
        searchWindowController.dismiss()
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
                if let recoveryUseCase = self.recoveryUseCase, !self.preservesRecoveryOnClose {
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
        editorGroupActivationTask?.cancel()
        editorGroupActivationTask = nil
        cancelOpenDocumentCompare(superseded: true)
        window?.delegate = nil
        fileUseCase?.setLiveReloadEnabled(false)
        fileUseCase?.onExternalChanges = nil
        fileUseCase?.onLoadingProgress = nil
        workspace.onChange = nil
        editorGroupRouter?.onEditorGroupFocus = nil
        activeEditor.onEdit = nil
        (activeEditor as? any EditorStatusReportingPort)?.onEditorStatusChange = nil
        if let foldingEditor = activeEditor as? any FoldingEditorPort {
            foldingEditor.onFoldStateChange = nil
            foldingEditor.invalidate()
        }
        languageUseCase?.onStateChange = nil
        documentIntelligenceUseCase?.cancel()
        commandPalettePanel.dismiss()
        symbolOutlinePanel.dismiss()
        commandBar.tearDown()
        extensionUseCase?.onStateChange = nil
        workspaceBrowserUseCase?.onStateChange = nil
        editorBinding = nil
        errorPresenter = nil
        editorGroupWorkspace.tearDown()
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
        window?.makeKeyAndOrderFront(nil)
        renderEditorGroups(workspace.snapshot(), requestFocus: true)
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
        searchPanel.window?.contentView?.layoutSubtreeIfNeeded()
        return SearchPanelSmokeState(
            isVisible: !searchPanel.isHidden,
            height: searchPanel.isHidden ? 0 : searchPanel.frame.height
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
            documentCount: workspace.snapshot().tabs.count,
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
        return L10n.text("Publisher: %1$@\nFingerprint: %2$@\nVersion: %3$@\nPackage: %4$@\n\nData access and destination:\n%5$@\n\nAffected signed package identities:\n%6$@\n\nGrants last until revoked or identity changes. Publisher revoke is durable across restart until deliberate Reset. No network, filesystem, environment, clock, or process access is exposed.", L10n.argument(item.manifest.publisher.id), L10n.argument(item.publisherFingerprint), L10n.argument(item.manifest.version), L10n.argument(item.packageDigest), L10n.argument(requested), L10n.argument(affected))
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

    @objc public func performToggleBlockComment(_ sender: Any?) {
        guard blockCommentsAreActionable,
              case .accepted = languageUseCase?.toggleBlockComment() else { return }
        activeEditor.focus()
    }

    @objc public func performShowLanguageChooser(_ sender: Any?) {
        guard workspaceInteractionsAreActionable else { return }
        let menu = makeLanguageStatusMenu()
        menu.popUp(
            positioning: LanguageMenuBuilder.positioningItem(in: menu),
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
        if keepsClosedWindowForReopen, window?.isVisible == false { showAndFocus() }
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

    @objc public func performChangeTheme(_ sender: NSMenuItem) {
        guard !terminationReviewInProgress,
              let raw = sender.representedObject as? String,
              let mode = AppAppearanceMode(rawValue: raw) else { return }
        onThemeRequested?(mode)
    }

    func performActivate(_ id: TabID) {
        guard workspaceInteractionsAreActionable,
              provisionalEditorGroupLayout == nil else { return }
        let layout = editorGroupLayout.snapshot
        let cachedGroups = layout.visibleGroups.filter {
            cachedGroupIndex(for: id, in: $0, layout: layout) != nil
        }
        let groups = cachedGroups.isEmpty
            ? layout.visibleGroups.filter { layout.tabIDs(in: $0).contains(id) }
            : cachedGroups
        let group = groups.contains(layout.focusedGroup) ? layout.focusedGroup : (groups.first ?? .primary)
        performActivate(id, in: group)
    }

    private func performActivate(_ id: TabID, in group: EditorGroupID) {
        guard workspaceInteractionsAreActionable else { return }
        let snapshot = latestWorkspaceSnapshot ?? workspace.snapshot()
        if selectEditorGroupTabIncrementally(id, in: group, workspace: snapshot) {
            renderLayoutAndActivate(
                tabID: id,
                group: group,
                workspace: snapshot,
                selectionAppliedIncrementally: true
            )
        } else if editorGroupLayout.select(id, in: group) {
            renderLayoutAndActivate(tabID: id, group: group, workspace: snapshot)
        }
    }

    private func renderLayoutAndActivate(
        tabID: TabID,
        group: EditorGroupID,
        workspace snapshot: WorkspaceSnapshot? = nil,
        selectionAppliedIncrementally: Bool = false
    ) {
        let snapshot = snapshot ?? workspace.snapshot()
        requestedEditorGroupSelection = (tabID, group)
        applyEditorGroupOrientation()
        if !selectionAppliedIncrementally {
            editorGroupWorkspace.apply(workspace: snapshot, layout: editorGroupLayout.snapshot)
            bindEditorGroupContextValidation()
        }
        let selectedTab = cachedWorkspaceTab(for: tabID, workspace: snapshot)
            ?? (!selectionAppliedIncrementally ? linearWorkspaceTab(for: tabID, workspace: snapshot) : nil)
        if let buffer = selectedTab?.buffer {
            editorGroupRouter?.display(buffer, in: group)
        }
        editorGroupRouter?.activateEditorGroup(group)
        editorGroupActivationTask?.cancel()
        if snapshot.activeBuffer == selectedTab?.buffer {
            if !selectionAppliedIncrementally { editorBinding.render(snapshot) }
            activeEditor.focus()
            if requestedEditorGroupSelection?.tabID == tabID,
               requestedEditorGroupSelection?.group == group {
                requestedEditorGroupSelection = nil
            }
            return
        }
        editorGroupActivationTask = Task { @MainActor [weak self] in
            guard let self, self.workspaceInteractionsAreActionable else { return }
            guard !Task.isCancelled else { return }
            if case .applied = await self.workspace.activate(tabID: tabID) {
                guard !Task.isCancelled else { return }
                self.activeEditor.focus()
            }
            if self.requestedEditorGroupSelection?.tabID == tabID,
               self.requestedEditorGroupSelection?.group == group {
                self.requestedEditorGroupSelection = nil
            }
        }
    }

    private func performEditorGroupFocus(_ group: EditorGroupID) {
        guard workspaceInteractionsAreActionable,
              provisionalEditorGroupLayout == nil,
              editorGroupLayout.snapshot.orientation != nil,
              editorGroupLayout.snapshot.focusedGroup != group,
              let tabID = editorGroupLayout.snapshot.selectedTabID(in: group) else { return }
        performActivate(tabID, in: group)
    }

    private func performEditorGroupAction(_ action: EditorGroupWorkspaceView.Action) {
        guard workspaceInteractionsAreActionable,
              provisionalEditorGroupLayout == nil else { return }
        switch action {
        case .select(let tabID, let group):
            performActivate(tabID, in: group)
        case .reorder(let tabID, let group, let index):
            performGroupReorder(tabID: tabID, group: group, groupIndex: index)
        case .split(let tabID, let source, let orientation, let operation):
            performGroupTransfer(tabID: tabID, source: source, orientation: orientation, operation: operation)
        case .splitAdjacent(let tabID, let source, let target, let zone, let operation):
            performAdjacentGroupSplit(tabID: tabID, source: source, target: target, zone: zone, operation: operation)
        case .move(let tabID, let source, let destination):
            performGroupTransfer(
                tabID: tabID,
                source: source,
                orientation: editorGroupLayout.snapshot.orientation,
                operation: .move,
                destination: destination
            )
        case .clone(let tabID, let source, let destination):
            performGroupTransfer(
                tabID: tabID,
                source: source,
                orientation: editorGroupLayout.snapshot.orientation,
                operation: .copy,
                destination: destination
            )
        case .transfer(let tabID, let source, let destination, let index, let operation):
            performGroupTransfer(tabID: tabID, source: source, orientation: editorGroupLayout.snapshot.orientation,
                                 operation: operation, destination: destination, insertionIndex: index)
        case .focus(let group):
            performEditorGroupFocus(group)
        case .close(let tabID, let group):
            performClose(tabID, in: group)
        case .context(let tabID, let group, let contextAction):
            performContextAction(contextAction, for: tabID, in: group)
        }
    }

    @discardableResult
    func performClose(_ id: TabID, decision: CloseDecision? = nil) -> Task<Void, Never> {
        guard workspaceInteractionsAreActionable else { return Task {} }
        return performClose(tabIDs: [id], decision: decision)
    }

    private func performClose(_ id: TabID, in group: EditorGroupID) {
        guard workspaceInteractionsAreActionable,
              provisionalEditorGroupLayout == nil,
              editorGroupLayout.select(id, in: group) else { return }
        editorGroupActivationTask?.cancel()
        requestedEditorGroupSelection = (id, group)
        let snapshot = workspace.snapshot()
        editorGroupWorkspace.apply(workspace: snapshot, layout: editorGroupLayout.snapshot)
        bindEditorGroupContextValidation()
        if let buffer = snapshot.tabs.first(where: { $0.id == id })?.buffer {
            editorGroupRouter?.display(buffer, in: group)
        }
        editorGroupRouter?.activateEditorGroup(group)
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.pendingCloseTasks.removeValue(forKey: token)
                if self.requestedEditorGroupSelection?.tabID == id,
                   self.requestedEditorGroupSelection?.group == group {
                    self.requestedEditorGroupSelection = nil
                }
            }
            guard case .applied = await self.workspace.activate(tabID: id) else { return }
            await self.requestClose(tabIDs: [id], retryingSaveTabID: nil)
        }
        pendingCloseTasks[token] = task
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
        let layout = editorGroupLayout.snapshot
        let strip = tabStrip(for: layout.focusedGroup)
        (strip ?? tabStrip).showDocumentSwitcher()
    }

    @objc public func performCompareWithOpenDocument(_ sender: Any? = nil) {
        guard let source = workspace.snapshot().tabs.first(where: \.isActive) else { return }
        beginOpenDocumentCompare(source: source, initiatingGroup: editorGroupLayout.snapshot.focusedGroup)
    }

    func waitForOpenDocumentCompare() async {
        await openDocumentCompareTask?.value
    }

    private func beginOpenDocumentCompare(source: TabSnapshot, initiatingGroup: EditorGroupID) {
        guard workspaceInteractionsAreActionable,
              workspace.snapshot().tabs.count >= 2 else { return }
        cancelOpenDocumentCompare(superseded: true)
        openDocumentCompareGeneration &+= 1
        let generation = openDocumentCompareGeneration
        openDocumentCompareRevisions = [source.id: source.buffer.revision]
        openDocumentCompareFocusGeneration = generation
        let candidates = openDocumentComparisonUseCase.eligibleTabs(excluding: source.id)
        openDocumentCompareTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.openDocumentCompareGeneration == generation {
                    self.openDocumentCompareTask = nil
                    self.openDocumentCompareRevisions.removeAll()
                }
                if self.openDocumentCompareFocusGeneration == generation {
                    self.openDocumentCompareFocusGeneration = nil
                    if !self.hasTornDownWindow, self.openDocumentComparePresenter.restoresEditorFocusAfterDismissal {
                        self.restoreEditorFocus(to: initiatingGroup)
                    }
                }
            }
            guard let targetID = await self.openDocumentComparePresenter.chooseTarget(
                source: source,
                candidates: candidates,
                attachedTo: self.window
            ), !Task.isCancelled,
               self.openDocumentCompareGeneration == generation else { return }
            do {
                let comparison = try self.openDocumentComparisonUseCase.capture(
                    leftTabID: source.id,
                    rightTabID: targetID
                )
                self.openDocumentCompareRevisions = [
                    comparison.left.tabID: comparison.left.revision,
                    comparison.right.tabID: comparison.right.revision,
                ]
                let content = self.compareContent(comparison)
                try await self.openDocumentComparePresenter.present(
                    content,
                    attachedTo: self.window,
                    isCurrent: { [weak self] in
                        self?.openDocumentComparisonIsCurrent(generation: generation) == true
                    }
                )
            } catch let error as OpenDocumentComparison.Error {
                guard error != .cancelled,
                      self.openDocumentCompareGeneration == generation else { return }
                self.openDocumentComparePresenter.presentFailure(error, attachedTo: self.window)
            } catch {
                guard self.openDocumentCompareGeneration == generation else { return }
                self.openDocumentComparePresenter.presentFailure(.cancelled, attachedTo: self.window)
            }
        }
    }

    private func compareContent(_ comparison: OpenDocumentComparison) -> OpenDocumentCompareContent {
        let duplicateTitle = comparison.left.title == comparison.right.title
        return OpenDocumentCompareContent(
            title: L10n.text("Diff — %1$@ ↔ %2$@", L10n.argument(comparison.left.title), L10n.argument(comparison.right.title)),
            leftTitle: duplicateTitle
                ? "\(comparison.left.title) — \(comparison.left.fullPath ?? "Untitled")"
                : comparison.left.title,
            rightTitle: duplicateTitle
                ? "\(comparison.right.title) — \(comparison.right.fullPath ?? "Untitled")"
                : comparison.right.title,
            leftText: comparison.left.text,
            rightText: comparison.right.text,
            titleKey: "Diff — %1$@ ↔ %2$@",
            titleArguments: [comparison.left.title, comparison.right.title]
        )
    }

    private func openDocumentComparisonIsCurrent(generation: UInt64) -> Bool {
        guard openDocumentCompareGeneration == generation,
              !hasTornDownWindow,
              workspaceInteractionsAreActionable else { return false }
        let revisions = Dictionary(uniqueKeysWithValues: workspace.snapshot().tabs.map {
            ($0.id, $0.buffer.revision)
        })
        return openDocumentCompareRevisions.allSatisfy { revisions[$0.key] == $0.value }
    }

    private func invalidateOpenDocumentCompareIfNeeded(_ snapshot: WorkspaceSnapshot) {
        guard !openDocumentCompareRevisions.isEmpty, !openDocumentComparePresenter.hasPresentedSnapshot else { return }
        let revisions = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.id, $0.buffer.revision) })
        guard openDocumentCompareRevisions.contains(where: { revisions[$0.key] != $0.value }) else { return }
        cancelOpenDocumentCompare()
    }

    private func cancelOpenDocumentCompare(superseded: Bool = false) {
        openDocumentCompareTask?.cancel()
        openDocumentComparePresenter.cancelOutstandingComparisons()
        if superseded {
            openDocumentCompareTask = nil
            openDocumentCompareRevisions.removeAll()
            openDocumentCompareFocusGeneration = nil
        }
    }

    private func restoreEditorFocus(to group: EditorGroupID) {
        let layout = editorGroupLayout.snapshot
        let restoredGroup = layout.orientation == nil ? .primary : group
        editorGroupRouter?.activateEditorGroup(restoredGroup)
        activeEditor.focus()
    }

    @objc public func performShowCommandPalette(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable,
              let menu = NSApplication.shared.mainMenu else { return }
        commandPalettePanel.present(
            menu: menu,
            excludingAction: #selector(performShowCommandPalette(_:)),
            relativeTo: commandBar
        )
    }

    public func applyPreferences(_ settings: AppSettings) {
        let languageChanged = appPreferences.appLanguage != settings.appLanguage
        appPreferences = settings
        fileUseCase?.setLiveReloadEnabled(settings.liveFileReloadEnabled)
        searchPanel.applyPreferences(settings)
        commandBar.setBarVisible(settings.menuBarVisible)
        statusBar.isHidden = !settings.statusBarVisible
        statusBarHeightConstraint?.constant = settings.statusBarVisible ? 24 : 0
        for group in editorGroupLayout.snapshot.visibleGroups { tabStrip(for: group)?.applyPreferences(settings) }
        if languageChanged { refreshLocalization(catalog: LocalizationCatalog(language: settings.appLanguage)) }
    }

    public func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        workspaceSidebar.refreshLocalization(catalog: catalog)
        searchPanel.refreshLocalization(catalog: catalog)
        liveFileBanner.refreshLocalization(catalog: catalog)
        persistenceBanner.refreshLocalization(catalog: catalog)
        statusBar.refreshLocalization(catalog: catalog)
        extensionsPanel.refreshLocalization(catalog: catalog)
        symbolOutlinePanel.refreshLocalization(catalog: catalog)
        commandPalettePanel.refreshLocalization(catalog: catalog)
        (openDocumentComparePresenter as? NativeOpenDocumentComparePresenter)?.refreshLocalization(catalog: catalog)
        (fileConflictPresenter as? NativeFilePanelAdapter)?.refreshLocalization(catalog: catalog)
        (navigationPresenter as? NativeEditorNavigationPresenter)?.refreshLocalization(catalog: catalog)
        for group in editorGroupLayout.snapshot.visibleGroups {
            editorGroupWorkspace.pane(for: group)?.refreshLocalization(catalog: catalog)
        }
        for case let zone as EditorGroupDropZoneView in editorGroupWorkspace.dropOverlay.subviews {
            zone.refreshLocalization(catalog: catalog)
        }
        renderFileFormatStatus()
        renderLanguageState(languageState)
        if let displayedExtensionError {
            setStatus(extensionStatus, text: catalog.text("Extension error: %1$@", arguments: [PresentationErrorText.message(displayedExtensionError, catalog: catalog)]), warning: true)
        } else {
            renderExtensionState(extensionState)
        }
        refreshLiveFileBanner()
        if let symbolPause {
            setStatus(symbolStatus, text: catalog.text(symbolPause.title, arguments: [symbolPause.amount]), warning: true)
            symbolStatus.toolTip = catalog.text(symbolPause.help, arguments: [symbolPause.limit])
        } else {
            let count = currentDocumentOutline?.symbols.count ?? 0
            setStatus(symbolStatus, text: count == 0 ? catalog.text("Symbols") : catalog.text("Symbols %1$@", arguments: [String(count)]), warning: false)
            symbolStatus.setAccessibilityValue(catalog.text("%1$@ current document symbols", arguments: [String(count)]))
        }
    }

    private func refreshLiveFileBanner() {
        guard let tab = workspace.snapshot().tabs.first(where: \.isActive),
              let change = fileUseCase?.externalChanges[tab.id] else { liveFileBanner.show(nil); return }
        liveFileBanner.show(change == .conflict
            ? L10n.text("%1$@ changed on disk. Your unsaved edits were kept.", tab.title)
            : L10n.text("%1$@ is unavailable on disk. Your contents were kept.", tab.title))
    }

    @objc private func performKeepEditingExternalFile(_ sender: Any?) {
        guard let id = workspace.snapshot().tabs.first(where: \.isActive)?.id else { return }
        fileUseCase?.dismissExternalChange(for: id)
    }

    @objc private func performReloadExternalFile(_ sender: Any?) {
        guard workspaceInteractionsAreActionable, fileUseCase != nil,
              let tab = workspace.snapshot().tabs.first(where: \.isActive), let window else { return }
        if tab.isDirty {
            let alert = NSAlert()
            alert.messageText = L10n.text("Reload %1$@ from disk?", L10n.argument(tab.title))
            alert.informativeText = L10n.text("Your unsaved edits will be replaced by the file on disk.")
            alert.addButton(withTitle: L10n.text("Cancel"))
            alert.addButton(withTitle: L10n.text("Reload"))
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn else { return }
                self?.startExplicitLiveReload(tabID: tab.id, revision: tab.buffer.revision)
            }
        } else {
            startExplicitLiveReload(tabID: tab.id, revision: nil)
        }
    }

    private func startExplicitLiveReload(tabID: TabID, revision: UInt64?) {
        guard workspaceInteractionsAreActionable, let fileUseCase else { return }
        let token = UUID()
        pendingFileCommandTasks[token] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingFileCommandTasks.removeValue(forKey: token) }
            await fileUseCase.refreshFromDisk(tabID: tabID, discardingRevision: revision)
        }
    }

    public func applicationMainMenuDidChange(_ menu: NSMenu) {
        commandBar.apply(mainMenu: menu)
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
                    text: L10n.text("Completion paused · %1$@ MiB", L10n.argument(actual / 1_024 / 1_024)),
                    warning: true
                )
                self.symbolPause = ("Completion paused · %1$@ MiB", String(actual / 1_024 / 1_024), "Completion limit: %1$@ bytes", String(maximum))
                self.symbolStatus.toolTip = L10n.text("Completion limit: %1$@ bytes", L10n.argument(maximum))
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
                self.symbolPause = nil
                self.currentDocumentOutline = outline
                self.setStatus(
                    self.symbolStatus,
                    text: outline.symbols.isEmpty ? L10n.text("Symbols") : L10n.text("Symbols %1$@", L10n.argument(outline.symbols.count)),
                    warning: false
                )
                self.symbolStatus.setAccessibilityValue(L10n.text("%1$@ current document symbols", L10n.argument(outline.symbols.count)))
                self.symbolOutlinePanel.present(symbols: outline.symbols, relativeTo: self.statusBar)
            case .overBudget(let actual, let maximum):
                self.setStatus(
                    self.symbolStatus,
                    text: L10n.text("Symbols paused · %1$@ MiB", L10n.argument(actual / 1_024 / 1_024)),
                    warning: true
                )
                self.symbolPause = ("Symbols paused · %1$@ MiB", String(actual / 1_024 / 1_024), "Symbol outline limit: %1$@ bytes", String(maximum))
                self.symbolStatus.toolTip = L10n.text("Symbol outline limit: %1$@ bytes", L10n.argument(maximum))
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
        let menu = DuckpadMainMenuFactory.makeFileFormatStatusMenu(target: self)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: fileFormatStatus.bounds.height + 2),
            in: fileFormatStatus
        )
    }

    @objc public func performShowLineEndingMenu(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable, fileUseCase != nil else { return }
        let button = statusBar.lineEndingButton
        let menu = DuckpadMainMenuFactory.makeLineEndingMenu(target: self)
        MenuLocalization.apply(to: menu)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 2),
            in: button
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
              let context = workspace.activeFileContext(),
              context.binding?.isReadOnly != true else { return }
        beginFileCommandTask { [weak self] in
            await self?.routeAcceptedSaveFile(expectedContext: context)
        }
    }

    @objc public func performSaveFileAs(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable,
              let context = workspace.activeFileContext(),
              context.binding?.isReadOnly != true else { return }
        beginFileCommandTask { [weak self] in
            await self?.routeAcceptedSaveFileAs(expectedContext: context)
        }
    }

    @objc public func performSaveCopyAs(_ sender: Any? = nil) {
        guard workspaceInteractionsAreActionable,
              let context = workspace.activeFileContext(),
              context.binding?.isReadOnly != true else { return }
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

    private func showSearchPanel(replace: Bool) {
        let selectedText = appPreferences.fillFindWithSelection
            ? (activeEditor as? any EditorFindTextPort)?.selectedTextForFind(maximumUTF16Length: appPreferences.findSelectionMaximumCharacters)
            : nil
        _ = searchWindowController
        searchPanel.show(replace: replace, selectedText: selectedText)
        searchWindowController.present(in: window)
    }

    @objc public func performShowFind(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        showSearchPanel(replace: false)
    }
    @objc public func performShowReplace(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        showSearchPanel(replace: true)
    }
    @objc public func performFindNext(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        if searchPanel.isHidden { showSearchPanel(replace: false); return }
        routeFind(searchPanel.currentQuery(direction: .forward))
    }
    @objc public func performFindPrevious(_ sender: Any? = nil) {
        guard !terminationReviewInProgress else { return }
        if searchPanel.isHidden { showSearchPanel(replace: false); return }
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
        showSearchPanel(replace: false)
        searchPanel.show(tab: .folder)
        searchWindowController.present(in: window)
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

    @objc public func performMoveActiveTabToGroupRight(_ sender: Any? = nil) {
        performActiveTabGroupTransfer(orientation: .sideBySide, operation: .move)
    }

    @objc public func performMoveActiveTabToGroupDown(_ sender: Any? = nil) {
        performActiveTabGroupTransfer(orientation: .stacked, operation: .move)
    }

    @objc public func performCloneActiveTabToGroupRight(_ sender: Any? = nil) {
        performActiveTabGroupTransfer(orientation: .sideBySide, operation: .copy)
    }

    @objc public func performCloneActiveTabToGroupDown(_ sender: Any? = nil) {
        performActiveTabGroupTransfer(orientation: .stacked, operation: .copy)
    }

    @objc public func performFocusOtherEditorGroup(_ sender: Any? = nil) {
        guard editorGroupLayout.snapshot.orientation != nil else { return }
        let layout = editorGroupLayout.snapshot
        let groups = layout.visibleGroups
        guard let index = groups.firstIndex(of: layout.focusedGroup) else { return }
        performEditorGroupFocus(groups[(index + 1) % groups.count])
    }

    @objc public func performCloseEditorGroup(_ sender: Any? = nil) {
        let layout = editorGroupLayout.snapshot
        closeEditorGroup(layout.focusedGroup == .primary && layout.visibleGroups.count == 2 ? .secondary : layout.focusedGroup)
    }

    private func closeEditorGroup(_ group: EditorGroupID) {
        guard workspaceInteractionsAreActionable,
              provisionalEditorGroupLayout == nil,
              editorGroupRouter != nil,
              editorGroupLayout.snapshot.visibleGroups.contains(group),
              editorGroupLayout.snapshot.orientation != nil else { return }
        editorGroupActivationTask?.cancel()
        requestedEditorGroupSelection = nil
        let previousLayout = editorGroupLayout.snapshot
        editorGroupLayout.closeGroup(group)
        let snapshot = workspace.snapshot()
        reconcileEditorGroupRoutes(from: previousLayout, to: editorGroupLayout.snapshot, workspace: snapshot)
        reconcileEditorGroups(snapshot)
        rebuildEditorGroupIndexCache(editorGroupLayout.snapshot, workspace: snapshot)
        editorGroupWorkspace.apply(workspace: snapshot, layout: editorGroupLayout.snapshot)
        bindEditorGroupContextValidation()
        routeSelectedEditorGroups(snapshot)
        editorBinding.render(snapshot)
        activeEditor.focus()
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
                && workspace.activeFileContext()?.binding?.isReadOnly != true
        }
        if let lineEnding = fileLineEndingChoice(for: menuItem.action) {
            menuItem.state = activeTextFileFormat.lineEnding == lineEnding ? .on : .off
            return workspaceInteractionsAreActionable && fileUseCase != nil
                && workspace.activeFileContext()?.binding?.isReadOnly != true
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
        if menuItem.action == #selector(performChangeTheme(_:)) {
            menuItem.state = menuItem.representedObject as? String == currentAppearanceMode?().rawValue ? .on : .off
            return !terminationReviewInProgress && onThemeRequested != nil
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
        case #selector(performToggleBlockComment(_:)):
            return blockCommentsAreActionable
        case #selector(performCloseActiveTab(_:)),
             #selector(performNextTab(_:)),
             #selector(performPreviousTab(_:)),
             #selector(performLastUsedTab(_:)),
             #selector(performShowDocumentSwitcher(_:)),
             #selector(performCompareWithOpenDocument(_:)),
             #selector(performShowCommandPalette(_:)),
             #selector(performMoveActiveTabLeft(_:)),
             #selector(performMoveActiveTabRight(_:)),
             #selector(performOpenFile(_:)),
             #selector(performToggleLineComment(_:)),
             #selector(performShowLanguageChooser(_:)),
             #selector(performShowExtensions(_:)):
            if menuItem.action == #selector(performCompareWithOpenDocument(_:)) {
                return workspaceInteractionsAreActionable && workspace.snapshot().tabs.count >= 2
            }
            return workspaceInteractionsAreActionable
        case #selector(performSaveFile(_:)), #selector(performSaveFileAs(_:)), #selector(performSaveCopyAs(_:)):
            return workspaceInteractionsAreActionable && fileUseCase != nil
                && workspace.activeFileContext()?.binding?.isReadOnly != true
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
        case #selector(performMoveActiveTabToGroupRight(_:)):
            return canPerformActiveTabGroupTransfer(orientation: .sideBySide, operation: .move)
        case #selector(performMoveActiveTabToGroupDown(_:)):
            return canPerformActiveTabGroupTransfer(orientation: .stacked, operation: .move)
        case #selector(performCloneActiveTabToGroupRight(_:)):
            return canPerformActiveTabGroupTransfer(orientation: .sideBySide, operation: .copy)
        case #selector(performCloneActiveTabToGroupDown(_:)):
            return canPerformActiveTabGroupTransfer(orientation: .stacked, operation: .copy)
        case #selector(performFocusOtherEditorGroup(_:)),
             #selector(performCloseEditorGroup(_:)):
            return editorGroupRouter != nil && workspaceInteractionsAreActionable
                && provisionalEditorGroupLayout == nil
                && editorGroupLayout.snapshot.orientation != nil
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
        guard editorCommandsAreActionable,
              editorGroupLayout.snapshot.orientation == nil else { return nil }
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

    private var blockCommentsAreActionable: Bool {
        guard workspaceInteractionsAreActionable,
              let languageUseCase,
              case .ready = languageUseCase.state,
              let editor = activeEditor as? any LanguageEditorPort else { return false }
        return editor.canToggleBlockComment
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
        if workspaceInteractionsAreActionable, keepsClosedWindowForReopen, window?.isVisible == false { showAndFocus() }
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
        let loadingID = UUID()
        pendingWorkspaceFileReads[loadingID] = FileLoadingProgress(path: entry.relativePath,
            loadedByteCount: 0, totalByteCount: nil)
        renderEditorStatus()
        beginWorkspaceBrowserTask { [weak self] in
            defer {
                self?.pendingWorkspaceFileReads.removeValue(forKey: loadingID)
                self?.renderEditorStatus()
            }
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
        pendingWorkspaceFileReads.removeAll()
        renderEditorStatus()
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
            let resolved = await resolve(fileOutcome: outcome, accessRecoveryContext: context, conversion: conversion) { [weak self] in
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
              context.binding?.isReadOnly != true,
              workspace.activeFileContext() == context,
              let url = await filePanels?.chooseSaveURL(suggestedName: context.title, attachedTo: window),
              workspaceInteractionsAreActionable || acceptedBeforeTermination,
              !hasTornDownWindow,
              workspace.activeFileContext() == context else { return }
        let outcome = await resolve(fileOutcome: await fileUseCase.saveAs(
            url,
            conversion: conversion,
            expectedContext: context
        ), accessRecoveryContext: context, conversion: conversion) { [weak self] in
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
        guard !hasTornDownWindow, expectedContext.binding?.isReadOnly != true,
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
        ), accessRecoveryContext: expectedContext, savesCopy: true) { [weak self] in
            self?.beginFileCommandTask { [weak self] in
                await self?.routeSaveCopyAs(expectedContext: expectedContext)
            }
        }
    }

    private func routeSaveAll() async {
        guard let fileUseCase else { return }
        let originalTabID = workspace.snapshot().tabs.first(where: \.isActive)?.id
        let originalGroup = editorGroupLayout.snapshot.focusedGroup
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
            let resolved = await resolve(fileOutcome: outcome, accessRecoveryContext: context) {}
            guard case .saved = resolved else { break }
            recordActiveDocumentURLIfSaved(resolved)
        }
        if let originalTabID,
           !hasTornDownWindow,
           workspace.snapshot().tabs.contains(where: { $0.id == originalTabID }) {
            if editorGroupLayout.snapshot.tabIDs(in: originalGroup).contains(originalTabID) {
                _ = editorGroupLayout.select(originalTabID, in: originalGroup)
                requestedEditorGroupSelection = (originalTabID, originalGroup)
                let snapshot = workspace.snapshot()
                editorGroupWorkspace.apply(workspace: snapshot, layout: editorGroupLayout.snapshot)
                bindEditorGroupContextValidation()
                if let buffer = snapshot.tabs.first(where: { $0.id == originalTabID })?.buffer {
                    editorGroupRouter?.display(buffer, in: originalGroup)
                }
                editorGroupRouter?.activateEditorGroup(originalGroup)
            }
            if workspace.snapshot().tabs.first(where: \.isActive)?.id != originalTabID {
                _ = await workspace.activate(tabID: originalTabID)
            }
            if requestedEditorGroupSelection?.tabID == originalTabID,
               requestedEditorGroupSelection?.group == originalGroup {
                requestedEditorGroupSelection = nil
            }
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

    // Production windows always have durable recovery. Hosts without it keep
    // the explicit save/discard gate instead of silently losing their buffers.
    var requiresTerminationDecision: Bool { recoveryUseCase == nil }

    private var preservesRecoveryOnClose = false
    private var liveReloadHiddenWindow = false

    public var requiresTerminationReview: Bool {
        hasDirtyDocuments || recoveryUseCase != nil || extensionUseCase != nil
            || !pendingFileCommandTasks.isEmpty
            || !pendingWorkspaceBrowserTasks.isEmpty || !pendingWorkspaceFileOpenTasks.isEmpty
    }

    @discardableResult
    public func flushRecovery(final: Bool = false) async -> Bool {
        guard let recoveryUseCase else { return true }
        guard workspace.snapshot().startup == .ready else { return false }
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

    /// Red-close, Quit, and system shutdown preserve the session without
    /// writing source files or asking for save/discard decisions.
    public func reviewDirtyDocumentsForTermination() async -> Bool {
        guard beginTerminationReviewAdmission() else { return false }
        return await performPreparedTerminationReview()
    }

    func beginTerminationReviewAdmission() -> Bool {
        guard !terminationReviewInProgress else { return false }
        terminationReviewInProgress = true
        fileUseCase?.suspendLiveReload()
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

    func prepareTerminationDocuments() async -> [TabSnapshot] {
        guard terminationReviewInProgress else { return [] }
        await waitForStartup()
        await waitForAcceptedWorkspaceTasks()
        await fileUseCase?.waitForLiveReload()
        await extensionUseCase?.suspendInvocationsAndWait()
        return workspace.snapshot().tabs.filter(\.isDirty)
    }

    var canSaveTerminationDocuments: Bool { fileUseCase != nil }

    func requestDirtyTabBatchDecision(_ tabs: [TabSnapshot], saveAvailable: Bool) async -> CloseDecision? {
        await dirtyDecisionPresenter?.decisionForAll(tabs, saveAvailable: saveAvailable, attachedTo: window)
    }

    func continuePreparedTerminationReview(
        batchDecision: DirtyTabBatchDecision? = nil,
        documentsPrepared: Bool = false
    ) async -> Bool {
        guard terminationReviewInProgress else { return false }
        return await performPreparedTerminationReview(batchDecision: batchDecision, documentsPrepared: documentsPrepared)
    }

    private func performPreparedTerminationReview(batchDecision: DirtyTabBatchDecision? = nil, documentsPrepared: Bool = false) async -> Bool {
        var approved = false
        defer {
            if !approved {
                terminationRetrySaveTabID = nil
                terminationReviewInProgress = false
                if !liveReloadHiddenWindow { fileUseCase?.resumeLiveReload() }
                extensionUseCase?.resumeInvocations()
                Task { @MainActor [weak workspaceBrowserUseCase] in
                    await workspaceBrowserUseCase?.resumeCommandsAndReconcile()
                }
                let snapshot = workspace.snapshot()
                updateWorkspaceInteractionAdmission(snapshot)
                editorBinding.render(snapshot)
            }
        }
        if !documentsPrepared { _ = await prepareTerminationDocuments() }
        if recoveryUseCase != nil {
            guard workspace.snapshot().startup == .ready else { return false }
            approved = await flushRecovery(final: true)
            if approved {
                preservesRecoveryOnClose = true
                // The recovery use case restores input for ordinary flush callers.
                // Keep this window locked while other windows finish quitting.
                activeEditor.setInputEnabled(false)
            }
            return approved
        }
        guard dirtyDecisionPresenter != nil || !hasDirtyDocuments else { return false }
        var batchDecision = batchDecision
        let dirtyTabs = workspace.snapshot().tabs.filter(\.isDirty)
        if batchDecision == nil, dirtyTabs.count > 1,
           let choice = await requestDirtyTabBatchDecision(dirtyTabs, saveAvailable: fileUseCase != nil) {
            if choice == .cancel { return false }
            batchDecision = DirtyTabBatchDecision(tabs: dirtyTabs, choice: choice)
        }
        let retrySaveTabID = terminationRetrySaveTabID
        terminationRetrySaveTabID = nil
        let outcome = await tabCloseCoordinator.reviewDirtyForTermination(
            saveAvailable: fileUseCase != nil,
            decision: { [weak self] tab, saveAvailable in
                if let choice = batchDecision?.decision(for: tab) { return choice }
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
        preservesRecoveryOnClose = false
        terminationRetrySaveTabID = nil
        guard terminationReviewInProgress else { return }
        terminationReviewInProgress = false
        if !liveReloadHiddenWindow { fileUseCase?.resumeLiveReload() }
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
            if self.keepsClosedWindowForReopen {
                // Keep the registered workspace available to Dock reopen and
                // within the live-window cap. Repeated red-close must not create
                // orphan archives beyond the bounded restore inventory.
                self.saveWindowFrame()
                self.liveReloadHiddenWindow = true
                sender.orderOut(nil)
                if self.terminationCoordinator?.permitsApplicationCommands == true {
                    self.cancelPreparedTerminationReview()
                }
            } else {
                self.permitsNextWindowClose = true
                self.approvedWindowClose(sender)
            }
        }
        return false
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        if liveReloadHiddenWindow && !terminationReviewInProgress {
            liveReloadHiddenWindow = false
            fileUseCase?.resumeLiveReload()
        }
        onBecameKey?()
    }

    private func saveWindowFrame() {
        guard hasPreparedWindowFrame, let window, window.isVisible, !window.inLiveResize else { return }
        framePersistence?.save(window)
    }

    public func windowDidResize(_ notification: Notification) { saveWindowFrame() }
    public func windowDidEndLiveResize(_ notification: Notification) { saveWindowFrame() }
    public func windowDidMove(_ notification: Notification) { saveWindowFrame() }

    public func refreshAppearance() {
        appliedThemePalette = nil
        updateLanguageTheme()
    }

    public func windowWillClose(_ notification: Notification) {
        saveWindowFrame()
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
        let menu = NSMenu(title: L10n.text("Language"))
        let automatic = menu.addItem(
            withTitle: L10n.text("Automatic Detection"),
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
        if let plainText = languageDefinitions.first(where: { $0.id == .plainText }) {
            let item = menu.addItem(
                withTitle: L10n.text("Plain Text"),
                action: #selector(performChooseLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = plainText.id.rawValue
            item.state = manuallySelectedID == plainText.id ? .on : .off
        }
        menu.addItem(.separator())
        LanguageMenuBuilder.append(
            languageDefinitions.filter { $0.id != .plainText },
            to: menu
        ) { [self] definition in
            let item = NSMenuItem(
                title: definition.displayName,
                action: #selector(performChooseLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = definition.id.rawValue
            item.state = manuallySelectedID == definition.id ? .on : .off
            return item
        }
        return menu
    }

    private func configureContent(
        injectedPresenter: (any PersistenceErrorPresenting)?
    ) -> any PersistenceErrorPresenting {
        let root = NSViewController()
        let dropView = FileDropView(frame: window?.contentLayoutRect ?? NSRect(
            x: 0, y: 0, width: 900, height: 620
        ))
        dropView.onFiles = { [weak self] urls in
            self?.openExternalURLs(urls)
        }
        dropView.onEffectiveAppearanceChange = { [weak self] in
            self?.refreshAppearance()
        }
        root.view = dropView
        root.view.addSubview(persistenceBanner)
        root.view.addSubview(commandBar)
        root.view.addSubview(liveFileBanner)
        liveFileBanner.reload.target = self
        liveFileBanner.reload.action = #selector(performReloadExternalFile(_:))
        liveFileBanner.dismiss.target = self
        liveFileBanner.dismiss.action = #selector(performKeepEditingExternalFile(_:))
        fileUseCase?.onExternalChanges = { [weak self] in self?.refreshLiveFileBanner() }
        fileUseCase?.onLoadingProgress = { [weak self] in self?.renderEditorStatus() }
        workspaceContentSplit.isVertical = true
        workspaceContentSplit.dividerStyle = .thin
        workspaceContentSplit.translatesAutoresizingMaskIntoConstraints = false
        workspaceContentSplit.addArrangedSubview(editorGroupWorkspace)
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
        statusBar.install(language: languageStatus, encoding: fileFormatStatus)
        statusBar.positionButton.target = self
        statusBar.positionButton.action = #selector(performGoToLine(_:))
        statusBar.lineEndingButton.target = self
        statusBar.lineEndingButton.action = #selector(performShowLineEndingMenu(_:))
        statusBar.modeButton.target = self
        statusBar.modeButton.action = #selector(performToggleOvertype(_:))
        statusBarHeightConstraint = statusBar.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            persistenceBanner.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            persistenceBanner.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            persistenceBanner.topAnchor.constraint(equalTo: root.view.topAnchor),
            commandBar.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            commandBar.topAnchor.constraint(equalTo: persistenceBanner.bottomAnchor),
            workspaceContentSplit.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            workspaceContentSplit.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            liveFileBanner.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
            liveFileBanner.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            liveFileBanner.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            workspaceContentSplit.topAnchor.constraint(equalTo: liveFileBanner.bottomAnchor),
            workspaceContentSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            statusBarHeightConstraint,
        ])
        if let mainMenu = NSApplication.shared.mainMenu {
            commandBar.apply(mainMenu: mainMenu)
        }
        window?.contentViewController = root
        return injectedPresenter ?? persistenceBanner
    }

    private func renderInitial(_ snapshot: WorkspaceSnapshot) {
        latestWorkspaceSnapshot = snapshot
        renderEditorGroups(snapshot)
        updateWorkspaceInteractionAdmission(snapshot)
        updateWindowTitle(snapshot)
        renderFileFormatStatus()
        renderEditorStatus()
    }

    private func renderEditorGroups(_ snapshot: WorkspaceSnapshot, requestFocus: Bool = false) {
        reconcileEditorGroups(snapshot)
        rebuildEditorGroupIndexCache(editorGroupLayout.snapshot, workspace: snapshot)
        editorGroupWorkspace.apply(workspace: snapshot, layout: editorGroupLayout.snapshot)
        bindEditorGroupContextValidation()
        routeSelectedEditorGroups(snapshot)
        editorBinding.render(snapshot, requestFocus: requestFocus)
    }

    private func reconcileEditorGroups(_ snapshot: WorkspaceSnapshot) {
        editorGroupReconcileCount += 1
        editorGroupReconcileTabInspectionCount += snapshot.tabs.count
        let previousLayout = editorGroupLayout.snapshot
        editorGroupLayout.reconcile(workspace: snapshot)
        reconcileEditorGroupRoutes(from: previousLayout, to: editorGroupLayout.snapshot, workspace: snapshot)
        if let editorGroupRouter,
           let activeTabID = snapshot.tabs.first(where: \.isActive)?.id {
            let layout = editorGroupLayout.snapshot
            let activeGroups = layout.visibleGroups.filter {
                layout.tabIDs(in: $0).contains(activeTabID)
            }
            if activeGroups.count > 1 {
                let preferredGroup = requestedEditorGroupSelection.flatMap {
                    $0.tabID == activeTabID ? $0.group : nil
                } ?? editorGroupRouter.activeEditorGroup
                if activeGroups.contains(preferredGroup) {
                    _ = editorGroupLayout.select(activeTabID, in: preferredGroup)
                }
            }
        }
        applyEditorGroupOrientation()
    }

    private func makeProvisionalEditorGroupLayout(
        durable: EditorGroupLayoutSnapshot,
        workspace: WorkspaceSnapshot
    ) -> EditorGroupLayoutSnapshot {
        let projected = EditorGroupLayoutModel(snapshot: durable)
        projected.reconcile(workspace: workspace)
        return projected.snapshot
    }

    private func applyEditorGroupOrientation(
        _ layout: EditorGroupLayoutSnapshot? = nil
    ) {
        let orientation = (layout ?? editorGroupLayout.snapshot).orientation
        guard let editorGroupRouter,
              editorGroupRouter.editorGroupOrientation != orientation else { return }
        editorGroupRouter.setEditorGroupOrientation(orientation)
    }

    private func applyEditorGroupWorkspace(
        snapshot: WorkspaceSnapshot,
        change: WorkspaceChange,
        previousLayout: EditorGroupLayoutSnapshot,
        currentLayout: EditorGroupLayoutSnapshot
    ) {
        if previousLayout.orientation == nil, currentLayout.orientation == nil {
            if case .activeTabChanged(_, let currentIndex) = change.kind,
               change.snapshot.tabs.indices.contains(currentIndex),
               requestedEditorGroupSelection?.tabID == change.snapshot.tabs[currentIndex].id,
               requestedEditorGroupSelection?.group == .primary,
               currentLayout.primarySelectedTabID == change.snapshot.tabs[currentIndex].id {
                return
            }
            tabStrip.apply(change: change)
        } else if previousLayout.orientation != nil,
                  currentLayout.orientation != nil,
                  applyIncrementalEditorGroupChange(
                      change,
                      previousLayout: previousLayout,
                      currentLayout: currentLayout
                  ) {
            return
        } else {
            editorGroupWorkspace.apply(workspace: snapshot, layout: currentLayout)
            bindEditorGroupContextValidation()
        }
    }

    private func applyIncrementalEditorGroupChange(
        _ change: WorkspaceChange,
        previousLayout: EditorGroupLayoutSnapshot,
        currentLayout: EditorGroupLayoutSnapshot
    ) -> Bool {
        switch change.kind {
        case .persistence:
            return true
        case .tabInserted(let workspaceIndex):
            return applyIncrementalEditorGroupInsertion(
                change,
                workspaceIndex: workspaceIndex,
                previousLayout: previousLayout,
                currentLayout: currentLayout
            )
        case .tabUpdated(let workspaceIndex), .bufferEdited(let workspaceIndex):
            guard change.snapshot.tabs.indices.contains(workspaceIndex) else { return false }
            let changedTab = change.snapshot.tabs[workspaceIndex]
            for group in currentLayout.visibleGroups {
                editorGroupIncrementalLookupCount += 1
                guard let groupIndex = editorGroupTabIndices[group]?[changedTab.id],
                      let strip = tabStrip(for: group) else { continue }
                let groupTab = TabSnapshot(
                    id: changedTab.id,
                    title: changedTab.title,
                    isActive: changedTab.id == currentLayout.selectedTabID(in: group),
                    isDirty: changedTab.isDirty,
                    isPinned: changedTab.isPinned,
                    buffer: changedTab.buffer,
                    fullPath: changedTab.fullPath
                )
                guard strip.apply(tab: groupTab, at: groupIndex) else { return false }
            }
            return true
        case .activeTabChanged:
            for group in currentLayout.visibleGroups {
                let previousTabID = previousLayout.selectedTabID(in: group)
                let currentTabID = currentLayout.selectedTabID(in: group)
                guard previousTabID != currentTabID else { continue }
                guard let previousTabID,
                      let currentTabID,
                      let strip = tabStrip(for: group),
                      let previousIndex = cachedGroupIndex(
                          for: previousTabID,
                          in: group,
                          layout: previousLayout
                      ),
                      let currentIndex = cachedGroupIndex(
                          for: currentTabID,
                          in: group,
                          layout: currentLayout
                      ),
                      let previous = groupTabSnapshot(
                          for: previousTabID,
                          isActive: false,
                          workspace: change.snapshot
                      ),
                      let current = groupTabSnapshot(
                          for: currentTabID,
                          isActive: true,
                          workspace: change.snapshot
                      ),
                      strip.applySelection(
                          previous: previous,
                          at: previousIndex,
                          current: current,
                          at: currentIndex
                      ) else { return false }
            }
            return true
        default:
            return false
        }
    }

    private func applyIncrementalEditorGroupInsertion(
        _ change: WorkspaceChange,
        workspaceIndex: Int,
        previousLayout: EditorGroupLayoutSnapshot,
        currentLayout: EditorGroupLayoutSnapshot
    ) -> Bool {
        guard previousLayout.orientation == currentLayout.orientation,
              change.snapshot.tabs.indices.contains(workspaceIndex) else { return false }
        let insertedTab = change.snapshot.tabs[workspaceIndex]
        let previousGroups = previousLayout.visibleGroups.filter {
            previousLayout.tabIDs(in: $0).contains(insertedTab.id)
        }
        let currentGroups = currentLayout.visibleGroups.filter {
            currentLayout.tabIDs(in: $0).contains(insertedTab.id)
        }
        guard previousGroups.isEmpty,
              currentGroups.count == 1,
              workspaceTabIndices[insertedTab.id] == workspaceIndex else { return false }
        let group = currentGroups[0]
        let previousIDs = previousLayout.tabIDs(in: group)
        let currentIDs = currentLayout.tabIDs(in: group)
        guard let localIndex = currentIDs.firstIndex(of: insertedTab.id) else { return false }
        var retainedIDs = currentIDs
        retainedIDs.remove(at: localIndex)
        guard retainedIDs == previousIDs else { return false }
        for other in currentLayout.visibleGroups where other != group {
            let previousOtherIDs = previousLayout.tabIDs(in: other)
            guard currentLayout.tabIDs(in: other) == previousOtherIDs,
                  let previousOtherSelection = previousLayout.selectedTabID(in: other),
                  previousOtherIDs.contains(previousOtherSelection),
                  currentLayout.selectedTabID(in: other) == previousOtherSelection,
                  let otherStrip = tabStrip(for: other),
                  otherStrip.tabIDs == previousOtherIDs,
                  otherStrip.activeTabID == previousOtherSelection else {
                return false
            }
        }
        guard let previousSelectedTabID = previousLayout.selectedTabID(in: group),
              previousIDs.contains(previousSelectedTabID),
              let selectedTabID = currentLayout.selectedTabID(in: group),
              currentIDs.contains(selectedTabID),
              let strip = tabStrip(for: group),
              strip.tabIDs == previousIDs,
              strip.activeTabID == previousSelectedTabID else { return false }
        var groupTabs: [TabSnapshot] = []
        groupTabs.reserveCapacity(currentIDs.count)
        for tabID in currentIDs {
            guard let tab = cachedWorkspaceTab(for: tabID, workspace: change.snapshot) else {
                return false
            }
            groupTabs.append(TabSnapshot(
                id: tab.id,
                title: tab.title,
                isActive: tab.id == selectedTabID,
                isDirty: tab.isDirty,
                isPinned: tab.isPinned,
                buffer: tab.buffer,
                fullPath: tab.fullPath
            ))
        }
        guard editorGroupWorkspace.applyFocus(layout: currentLayout) else { return false }
        let groupSnapshot = WorkspaceSnapshot(
            sessionID: change.snapshot.sessionID,
            tabs: groupTabs,
            activeBuffer: groupTabs.first(where: \.isActive)?.buffer,
            persistence: change.snapshot.persistence,
            startup: change.snapshot.startup
        )
        strip.apply(change: WorkspaceChange(
            snapshot: groupSnapshot,
            kind: .tabInserted(index: localIndex),
            failureEvent: change.failureEvent
        ))
        return true
    }

    private func tabStrip(for group: EditorGroupID) -> MultilineTabStripView? {
        editorGroupWorkspace.pane(for: group)?.tabStrip
    }

    private func rebuildEditorGroupIndexCache(
        _ layout: EditorGroupLayoutSnapshot,
        workspace snapshot: WorkspaceSnapshot
    ) {
        editorGroupTabIndices = Dictionary(uniqueKeysWithValues: layout.visibleGroups.map { group in
            (group, Dictionary(uniqueKeysWithValues: layout.tabIDs(in: group).enumerated().map {
                ($0.element, $0.offset)
            }))
        })
        workspaceTabIndices = Dictionary(uniqueKeysWithValues: snapshot.tabs.enumerated().map {
            ($0.element.id, $0.offset)
        })
        editorGroupIndexRebuildCount += 1
    }

    private func cachedGroupIndex(
        for tabID: TabID,
        in group: EditorGroupID,
        layout: EditorGroupLayoutSnapshot
    ) -> Int? {
        guard let index = editorGroupTabIndices[group]?[tabID],
              layout.tabIDs(in: group).indices.contains(index),
              layout.tabIDs(in: group)[index] == tabID else { return nil }
        return index
    }

    private func groupTabSnapshot(
        for tabID: TabID,
        isActive: Bool,
        workspace: WorkspaceSnapshot
    ) -> TabSnapshot? {
        guard let tab = cachedWorkspaceTab(for: tabID, workspace: workspace) else { return nil }
        return TabSnapshot(
            id: tab.id,
            title: tab.title,
            isActive: isActive,
            isDirty: tab.isDirty,
            isPinned: tab.isPinned,
            buffer: tab.buffer,
            fullPath: tab.fullPath
        )
    }

    private func cachedWorkspaceTab(
        for tabID: TabID,
        workspace: WorkspaceSnapshot
    ) -> TabSnapshot? {
        editorGroupCachedTabLookupCount += 1
        guard let index = workspaceTabIndices[tabID],
              workspace.tabs.indices.contains(index),
              workspace.tabs[index].id == tabID else { return nil }
        return workspace.tabs[index]
    }

    private func linearWorkspaceTab(
        for tabID: TabID,
        workspace: WorkspaceSnapshot
    ) -> TabSnapshot? {
        editorGroupLinearTabInspectionCount += workspace.tabs.count
        return workspace.tabs.first(where: { $0.id == tabID })
    }

    private func selectEditorGroupTabIncrementally(
        _ tabID: TabID,
        in group: EditorGroupID,
        workspace: WorkspaceSnapshot
    ) -> Bool {
        let layout = editorGroupLayout.snapshot
        guard cachedGroupIndex(for: tabID, in: group, layout: layout) != nil,
              groupTabSnapshot(for: tabID, isActive: true, workspace: workspace) != nil,
              let previousTabID = layout.selectedTabID(in: group) else { return false }
        if previousTabID != tabID {
            guard let strip = tabStrip(for: group),
                  let previousIndex = cachedGroupIndex(for: previousTabID, in: group, layout: layout),
                  let currentIndex = cachedGroupIndex(for: tabID, in: group, layout: layout),
                  let previous = groupTabSnapshot(
                      for: previousTabID,
                      isActive: false,
                      workspace: workspace
                  ),
                  let current = groupTabSnapshot(for: tabID, isActive: true, workspace: workspace),
                  strip.applySelection(
                      previous: previous,
                      at: previousIndex,
                      current: current,
                      at: currentIndex
                  ) else { return false }
        }
        editorGroupLayout.selectKnownMember(tabID, in: group)
        guard editorGroupWorkspace.applyFocus(layout: editorGroupLayout.snapshot) else { return false }
        return true
    }

    private func selectActiveEditorGroupIncrementally(
        workspace: WorkspaceSnapshot,
        currentIndex: Int
    ) -> Bool {
        guard workspace.tabs.indices.contains(currentIndex) else { return false }
        let activeTabID = workspace.tabs[currentIndex].id
        guard workspaceTabIndices[activeTabID] == currentIndex else { return false }
        let layout = editorGroupLayout.snapshot
        let activeGroups = layout.visibleGroups.filter {
            cachedGroupIndex(for: activeTabID, in: $0, layout: layout) != nil
        }
        guard !activeGroups.isEmpty else { return false }
        let preferredGroup = requestedEditorGroupSelection.flatMap {
            $0.tabID == activeTabID ? $0.group : nil
        } ?? editorGroupRouter?.activeEditorGroup ?? layout.focusedGroup
        let group = activeGroups.contains(preferredGroup) ? preferredGroup : activeGroups[0]
        if layout.focusedGroup != group || layout.selectedTabID(in: group) != activeTabID {
            editorGroupLayout.selectKnownMember(activeTabID, in: group)
        }
        guard editorGroupWorkspace.applyFocus(layout: editorGroupLayout.snapshot) else { return false }
        if requestedEditorGroupSelection?.tabID != activeTabID
            || requestedEditorGroupSelection?.group != group {
            guard let activeTab = cachedWorkspaceTab(for: activeTabID, workspace: workspace) else {
                return false
            }
            editorGroupRouter?.display(activeTab.buffer, in: group)
            editorGroupRouter?.activateEditorGroup(group)
        }
        return true
    }

    private func routeSelectedEditorGroups(
        _ snapshot: WorkspaceSnapshot,
        layout: EditorGroupLayoutSnapshot? = nil
    ) {
        guard let editorGroupRouter else { return }
        let layout = layout ?? editorGroupLayout.snapshot
        let tabsByID = Dictionary(uniqueKeysWithValues: snapshot.tabs.map { ($0.id, $0) })
        let visibleGroups = layout.visibleGroups
        for group in visibleGroups {
            guard let selected = layout.selectedTabID(in: group),
                  let buffer = tabsByID[selected]?.buffer else { continue }
            editorGroupRouter.display(buffer, in: group)
        }
        editorGroupRouter.activateEditorGroup(layout.focusedGroup)
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
        latestWorkspaceSnapshot = change.snapshot
        switch change.kind {
        case .bufferEdited, .persistence, .activeTabChanged: break
        default: fileUseCase?.updateLiveReloadDocuments()
        }
        refreshLiveFileBanner()
        invalidateOpenDocumentCompareIfNeeded(change.snapshot)
        if shouldInvalidateDocumentIntelligence(for: change) {
            documentIntelligenceTask?.cancel()
            documentIntelligenceTask = nil
            if shouldCancelCompletion(for: change) { documentIntelligenceUseCase?.cancel() }
            symbolOutlinePanel.dismiss()
            currentDocumentOutline = nil
            symbolPause = nil
            setStatus(symbolStatus, text: L10n.text("Symbols"), warning: false)
            symbolStatus.setAccessibilityValue(L10n.text("Current document symbols"))
        }
        let previousLayout = editorGroupLayoutSnapshot
        let currentLayout: EditorGroupLayoutSnapshot
        if change.kind.isRemovalPending {
            let provisional = makeProvisionalEditorGroupLayout(
                durable: editorGroupLayout.snapshot,
                workspace: change.snapshot
            )
            provisionalEditorGroupLayout = provisional
            currentLayout = provisional
            applyEditorGroupOrientation(provisional)
        } else if provisionalEditorGroupLayout != nil,
                  !editorGroupRemovalDidFinish(change.kind) {
            let provisional = makeProvisionalEditorGroupLayout(
                durable: editorGroupLayout.snapshot,
                workspace: change.snapshot
            )
            provisionalEditorGroupLayout = provisional
            currentLayout = provisional
            applyEditorGroupOrientation(provisional)
        } else {
            provisionalEditorGroupLayout = nil
            if case .activeTabChanged(_, let currentIndex) = change.kind {
                if !selectActiveEditorGroupIncrementally(
                    workspace: change.snapshot,
                    currentIndex: currentIndex
                ) {
                    reconcileEditorGroups(change.snapshot)
                }
            } else if shouldReconcileEditorGroups(for: change.kind) {
                reconcileEditorGroups(change.snapshot)
            }
            currentLayout = editorGroupLayout.snapshot
        }
        if editorGroupMembershipMayHaveChanged(change.kind) {
            rebuildEditorGroupIndexCache(currentLayout, workspace: change.snapshot)
        }
        applyEditorGroupWorkspace(
            snapshot: change.snapshot,
            change: change,
            previousLayout: previousLayout,
            currentLayout: currentLayout
        )
        updateWorkspaceInteractionAdmission(change.snapshot)
        let firstLanguageValidation = change.snapshot.startup == .ready && !languageValidated
        var registryReady = true
        if firstLanguageValidation {
            languageValidated = true
            registryReady = languageUseCase?.validateRegistry() ?? false
        }
        if shouldRouteSelectedEditorGroups(for: change.kind) {
            routeSelectedEditorGroups(change.snapshot, layout: currentLayout)
        }
        editorBinding.render(change)
        if searchHighlightBuffer != change.snapshot.activeBuffer {
            searchHighlightBuffer = change.snapshot.activeBuffer
            clearSearchHighlights()
            searchPanel.refreshMatchesAfterDocumentChange()
        }
        if terminationReviewInProgress {
            activeEditor.setInputEnabled(false)
        }
        updateWindowTitle(change.snapshot)
        renderFileFormatStatus()
        renderEditorStatus()
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
            if case .closeUnchanged(let ids) = event.retry {
                self.performClose(tabIDs: ids)
            } else {
                Task { [weak workspace] in _ = await workspace?.retry(event.retry) }
            }
        }
    }

    private func updateWorkspaceInteractionAdmission(_ snapshot: WorkspaceSnapshot) {
        let enabled = snapshot.startup == .ready && !terminationReviewInProgress
        let tabInteractionsEnabled = enabled && provisionalEditorGroupLayout == nil
        tabStrip.setInteractionsEnabled(tabInteractionsEnabled)
        for group in editorGroupLayoutSnapshot.visibleGroups where group != .primary {
            tabStrip(for: group)?.setInteractionsEnabled(tabInteractionsEnabled)
        }
        workspaceSidebar.setInteractionsEnabled(enabled && workspaceBrowserUseCase?.acceptsCommands == true)
        languageStatus.isEnabled = enabled
        symbolStatus.isEnabled = enabled && documentIntelligenceUseCase != nil
        let isReadOnly = workspace.activeFileContext()?.binding?.isReadOnly == true
        fileFormatStatus.isEnabled = enabled && fileUseCase != nil && !isReadOnly
        statusBar.lineEndingButton.isEnabled = fileFormatStatus.isEnabled
        statusBar.positionButton.isEnabled = enabled && actionableNavigationEditor != nil
        statusBar.modeButton.isEnabled = enabled && !isReadOnly && activeEditor is any EditorStatusReportingPort
        extensionStatus.isEnabled = enabled
    }

    private func shouldRefreshLanguage(for change: WorkspaceChange) -> Bool {
        switch change.kind {
        case .reset, .tabInserted, .activeTabChanged, .tabRemovalPending, .tabsRemovalPending, .tabRemoved, .tabsRemoved:
            return true
        case .tabUpdated(let index):
            return change.snapshot.tabs.indices.contains(index) && change.snapshot.tabs[index].isActive
        case .bufferEdited, .persistence, .tabsReordered:
            return false
        }
    }

    private func shouldRouteSelectedEditorGroups(for kind: WorkspaceChangeKind) -> Bool {
        switch kind {
        case .reset, .tabInserted, .tabRemovalPending, .tabsRemovalPending, .tabRemoved, .tabsRemoved:
            return true
        case .activeTabChanged, .tabUpdated, .bufferEdited, .persistence, .tabsReordered:
            return false
        }
    }

    private func shouldReconcileEditorGroups(for kind: WorkspaceChangeKind) -> Bool {
        switch kind {
        case .reset, .tabInserted, .activeTabChanged, .tabRemovalPending, .tabsRemovalPending, .tabRemoved, .tabsRemoved, .tabsReordered:
            return true
        case .tabUpdated, .bufferEdited, .persistence:
            return false
        }
    }

    private func editorGroupMembershipMayHaveChanged(_ kind: WorkspaceChangeKind) -> Bool {
        switch kind {
        case .reset, .tabInserted, .tabRemovalPending, .tabsRemovalPending, .tabRemoved, .tabsRemoved, .tabsReordered:
            return true
        case .activeTabChanged, .tabUpdated, .bufferEdited, .persistence:
            return false
        }
    }

    private func editorGroupRemovalDidFinish(_ kind: WorkspaceChangeKind) -> Bool {
        switch kind {
        case .reset, .tabRemoved, .tabsRemoved:
            return true
        case .tabInserted, .activeTabChanged, .tabUpdated, .bufferEdited,
             .tabRemovalPending, .tabsRemovalPending, .tabsReordered, .persistence:
            return false
        }
    }

    private func shouldInvalidateDocumentIntelligence(for change: WorkspaceChange) -> Bool {
        switch change.kind {
        case .bufferEdited, .reset, .tabInserted, .activeTabChanged, .tabRemovalPending, .tabsRemovalPending, .tabRemoved, .tabsRemoved:
            return true
        case .tabUpdated(let index):
            return change.snapshot.tabs.indices.contains(index) && change.snapshot.tabs[index].isActive
        case .persistence, .tabsReordered:
            return false
        }
    }

    private func shouldCancelCompletion(for change: WorkspaceChange) -> Bool {
        switch change.kind {
        case .reset, .tabInserted, .activeTabChanged, .tabRemovalPending, .tabsRemovalPending, .tabRemoved, .tabsRemoved:
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
        var batchDecision: DirtyTabBatchDecision?
        var requestedBatchDecision = false
        let outcome = await tabCloseCoordinator.close(
            tabIDs: tabIDs,
            saveAvailable: fileUseCase != nil,
            decision: { [weak self] tab, saveAvailable in
                if tab.id == retryingSaveTabID { return .save }
                if let forcedDecision { return forcedDecision }
                if !requestedBatchDecision {
                    requestedBatchDecision = true
                    if let self {
                        let targets = Set(tabIDs)
                        let dirtyTabs = self.workspace.snapshot().tabs.filter { targets.contains($0.id) && $0.isDirty }
                        if dirtyTabs.count > 1,
                           let choice = await self.requestDirtyTabBatchDecision(dirtyTabs, saveAvailable: saveAvailable) {
                            batchDecision = DirtyTabBatchDecision(tabs: dirtyTabs, choice: choice)
                        }
                    }
                }
                if batchDecision?.choice == .cancel { return .cancel }
                if let choice = batchDecision?.decision(for: tab) { return choice }
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
        alert.messageText = L10n.text("Save changes to %1$@ before closing?", L10n.argument(tab.title))
        alert.informativeText = L10n.text("Discard closes this exact reviewed revision without writing.")
        if saveAvailable { alert.addButton(withTitle: L10n.text("Save")) }
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.addButton(withTitle: L10n.text("Discard"))
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

    private func performGroupReorder(tabID: TabID, group: EditorGroupID, groupIndex: Int) {
        let snapshot = workspace.snapshot()
        var reorderedGroup = editorGroupLayout.snapshot.tabIDs(in: group)
        guard let source = reorderedGroup.firstIndex(of: tabID),
              reorderedGroup.indices.contains(groupIndex) else { return }
        reorderedGroup.remove(at: source)
        reorderedGroup.insert(tabID, at: groupIndex)
        var replacement = reorderedGroup.makeIterator()
        let groupSet = Set(reorderedGroup)
        let desiredOrder = snapshot.tabs.map(\.id).map { id in
            groupSet.contains(id) ? (replacement.next() ?? id) : id
        }
        guard let destination = desiredOrder.firstIndex(of: tabID) else { return }
        performMove(tabID, to: destination)
    }

    private func performActiveTabGroupTransfer(
        orientation: EditorGroupSplitOrientation,
        operation: EditorGroupDropOperation
    ) {
        let layout = editorGroupLayout.snapshot
        guard let tabID = layout.selectedTabID(in: layout.focusedGroup) else { return }
        performGroupTransfer(
            tabID: tabID,
            source: layout.focusedGroup,
            orientation: orientation,
            operation: operation
        )
    }

    private func otherEditorGroup(than source: EditorGroupID) -> EditorGroupID {
        editorGroupLayout.snapshot.visibleGroups.first(where: { $0 != source }) ?? source.other
    }

    private func reconcileEditorGroupRoutes(
        from previous: EditorGroupLayoutSnapshot, to current: EditorGroupLayoutSnapshot,
        workspace: WorkspaceSnapshot
    ) {
        let disappeared = Set(previous.visibleGroups).subtracting(current.visibleGroups)
        guard !disappeared.isEmpty else { return }
        let buffers = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0.buffer) })
        for source in disappeared {
            for tabID in previous.tabIDs(in: source) {
                guard let destination = current.visibleGroups.first(where: { current.tabIDs(in: $0).contains(tabID) }),
                      let buffer = buffers[tabID] else { continue }
                editorGroupRouter?.assign(buffer, from: source, to: destination, cloning: false)
            }
        }
        editorGroupRouter?.retainEditorGroups(Set(current.visibleGroups))
    }

    private func performAdjacentGroupSplit(
        tabID: TabID, source: EditorGroupID, target: EditorGroupID,
        zone: EditorGroupDropOverlay.Zone, operation: EditorGroupDropOperation
    ) {
        guard editorGroupRouter != nil, workspaceInteractionsAreActionable,
              provisionalEditorGroupLayout == nil,
              let buffer = workspace.snapshot().tabs.first(where: { $0.id == tabID })?.buffer,
              let destination = editorGroupLayout.splitAdjacent(
                  tabID: tabID, source: source, target: target, zone: zone, operation: operation
              ) else { return }
        applyEditorGroupOrientation()
        editorGroupRouter?.assign(buffer, from: source, to: destination, cloning: operation == .copy)
        let snapshot = workspace.snapshot()
        rebuildEditorGroupIndexCache(editorGroupLayout.snapshot, workspace: snapshot)
        routeSelectedEditorGroups(snapshot)
        renderLayoutAndActivate(tabID: tabID, group: destination)
        recoveryUseCase?.editorViewStateDidChange()
    }

    private func performGroupTransfer(
        tabID: TabID,
        source: EditorGroupID,
        orientation: EditorGroupSplitOrientation?,
        operation: EditorGroupDropOperation,
        destination: EditorGroupID? = nil,
        insertionIndex: Int? = nil
    ) {
        var destination = destination ?? otherEditorGroup(than: source)
        let workspaceSnapshot = workspace.snapshot()
        guard let orientation,
              canPerformGroupTransfer(
                  tabID: tabID,
                  source: source,
                  destination: destination,
                  orientation: orientation,
                  operation: operation
              ),
              let buffer = cachedWorkspaceTab(for: tabID, workspace: workspaceSnapshot)?.buffer
                ?? linearWorkspaceTab(for: tabID, workspace: workspaceSnapshot)?.buffer else { return }
        let previousLayout = editorGroupLayout.snapshot
        let destinationInsertionIndex = insertionIndex.map { index in
            if let existing = previousLayout.tabIDs(in: destination).firstIndex(of: tabID), existing < index {
                return index - 1
            }
            return index
        }
        let changed: Bool
        if editorGroupLayout.snapshot.orientation == nil {
            changed = editorGroupLayout.split(
                tabID: tabID,
                source: source,
                orientation: orientation,
                operation: operation
            )
        } else {
            switch operation {
            case .move:
                changed = editorGroupLayout.move(tabID, from: source, to: destination)
            case .copy:
                changed = editorGroupLayout.clone(tabID, from: source, to: destination)
            }
        }
        guard changed else { return }
        let updatedLayout = editorGroupLayout.snapshot
        if !updatedLayout.visibleGroups.contains(destination) {
            destination = updatedLayout.focusedGroup
        }
        reconcileEditorGroupRoutes(from: previousLayout, to: editorGroupLayout.snapshot, workspace: workspaceSnapshot)
        applyEditorGroupOrientation()
        rebuildEditorGroupIndexCache(editorGroupLayout.snapshot, workspace: workspaceSnapshot)
        editorGroupRouter?.assign(
            buffer,
            from: source,
            to: destination,
            cloning: operation == .copy
        )
        let layout = editorGroupLayout.snapshot
        if operation == .move,
           layout.orientation != nil,
           let sourceTabID = layout.selectedTabID(in: source),
           let sourceBuffer = cachedWorkspaceTab(
               for: sourceTabID,
               workspace: workspaceSnapshot
           )?.buffer {
            editorGroupRouter?.display(sourceBuffer, in: source)
        }
        renderLayoutAndActivate(tabID: tabID, group: destination)
        recoveryUseCase?.editorViewStateDidChange()
        if let insertionIndex = destinationInsertionIndex {
            let count = editorGroupLayout.snapshot.tabIDs(in: destination).count
            performGroupReorder(tabID: tabID, group: destination, groupIndex: min(insertionIndex, max(0, count - 1)))
        }
    }

    private func canPerformActiveTabGroupTransfer(
        orientation: EditorGroupSplitOrientation,
        operation: EditorGroupDropOperation
    ) -> Bool {
        let layout = editorGroupLayout.snapshot
        if layout.orientation != nil, layout.focusedGroup != .primary { return false }
        guard let tabID = layout.selectedTabID(in: layout.focusedGroup) else { return false }
        return canPerformGroupTransfer(
            tabID: tabID,
            source: layout.focusedGroup,
            destination: otherEditorGroup(than: layout.focusedGroup),
            orientation: orientation,
            operation: operation
        )
    }

    private func canPerformGroupTransfer(
        tabID: TabID,
        source: EditorGroupID,
        destination: EditorGroupID,
        orientation: EditorGroupSplitOrientation,
        operation: EditorGroupDropOperation
    ) -> Bool {
        guard editorGroupRouter != nil,
              workspaceInteractionsAreActionable,
              provisionalEditorGroupLayout == nil else { return false }
        let layout = editorGroupLayout.snapshot
        guard layout.orientation == nil || layout.orientation == orientation,
              layout.orientation == nil || layout.visibleGroups.contains(destination),
              source != destination,
              layout.tabIDs(in: source).contains(tabID) else { return false }
        let destinationContainsTab = layout.tabIDs(in: destination).contains(tabID)
        switch operation {
        case .copy:
            return !destinationContainsTab
        case .move:
            return layout.visibleGroups.contains(destination) || layout.tabIDs(in: source).count > 1
        }
    }

    private func bindEditorGroupContextValidation() {
        applyPreferences(appPreferences)
        bindEditorGroupContextValidation(tabStrip, group: .primary)
        for group in editorGroupLayout.snapshot.visibleGroups where group != .primary {
            if let strip = tabStrip(for: group) { bindEditorGroupContextValidation(strip, group: group) }
        }
    }

    private func bindEditorGroupContextValidation(
        _ strip: MultilineTabStripView,
        group: EditorGroupID
    ) {
        strip.onValidateContextAction = { [weak self] tabID, action in
            self?.validateContextAction(action, tabID: tabID, group: group) ?? false
        }
    }

    private func validateContextAction(
        _ action: TabContextAction,
        tabID: TabID,
        group: EditorGroupID
    ) -> Bool {
        switch action {
        case .moveToEditorGroup(let orientation):
            if editorGroupLayout.snapshot.orientation != nil, group != .primary { return false }
            return canPerformGroupTransfer(
                tabID: tabID,
                source: group,
                destination: otherEditorGroup(than: group),
                orientation: orientation,
                operation: .move
            )
        case .cloneToEditorGroup(let orientation):
            if editorGroupLayout.snapshot.orientation != nil, group != .primary { return false }
            return canPerformGroupTransfer(
                tabID: tabID,
                source: group,
                destination: otherEditorGroup(than: group),
                orientation: orientation,
                operation: .copy
            )
        case .focusOtherEditorGroup, .closeEditorGroup:
            return editorGroupRouter != nil
                && provisionalEditorGroupLayout == nil
                && editorGroupLayout.snapshot.orientation != nil
        case .compareWithOpenDocument:
            return workspaceInteractionsAreActionable && workspace.snapshot().tabs.count >= 2
        case .close, .setPinned, .copyFullPath, .openContainingFolder:
            return workspaceInteractionsAreActionable
        }
    }

    private func performContextAction(
        _ action: TabContextAction,
        for tabID: TabID,
        in group: EditorGroupID
    ) {
        guard workspaceInteractionsAreActionable else { return }
        switch action {
        case .close(let scope):
            if scope == .current { performClose(tabID, in: group) }
            else {
                performActivate(tabID, in: group)
                performClose(scope: scope, relativeTo: tabID)
            }
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
        case .moveToEditorGroup(let orientation):
            performGroupTransfer(
                tabID: tabID,
                source: group,
                orientation: orientation,
                operation: .move
            )
        case .cloneToEditorGroup(let orientation):
            performGroupTransfer(
                tabID: tabID,
                source: group,
                orientation: orientation,
                operation: .copy
            )
        case .focusOtherEditorGroup:
            performEditorGroupFocus(otherEditorGroup(than: group))
        case .closeEditorGroup:
            closeEditorGroup(group)
        case .compareWithOpenDocument:
            guard let source = workspace.snapshot().tabs.first(where: { $0.id == tabID }) else { return }
            beginOpenDocumentCompare(source: source, initiatingGroup: group)
        }
    }

    private func routeFind(_ query: SearchQuery) {
        guard workspaceInteractionsAreActionable,
              !query.pattern.isEmpty, let searchUseCase else { return }
        let buffer = workspace.snapshot().activeBuffer
        let operation = beginSearchOperation()
        searchPanel.presentStatus(key: "Searching…")
        searchTask = Task { [weak self] in
            defer { self?.finishSearchOperation(operation) }
            do {
                let match = try await searchUseCase.find(query)
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: match == nil ? "No matches" : "Match selected")
                if let self, let buffer, self.workspace.snapshot().activeBuffer == buffer,
                   !self.hasSearchHighlights(for: query, buffer: buffer) {
                    let result = try await searchUseCase.findAll(query)
                    guard self.searchOperationID == operation else { return }
                    self.presentSearchHighlights(result, query: query, buffer: buffer)
                }
            } catch SearchFailure.cancelled { }
            catch SearchFailure.noSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: "Select a non-empty range to search")
            }
            catch SearchFailure.invalidSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: "Selection changed; select a range again")
            }
            catch {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentFailure(prefix: "Search failed: %1$@", error: error)
            }
        }
    }

    private func routeFindAll(_ query: SearchQuery, incremental: Bool = false) {
        guard workspaceInteractionsAreActionable,
              !query.pattern.isEmpty, let searchUseCase else { return }
        let buffer = workspace.snapshot().activeBuffer
        let operation = beginSearchOperation()
        searchPanel.presentStatus(key: "Searching…")
        searchTask = Task { [weak self] in
            defer { self?.finishSearchOperation(operation) }
            do {
                let result = try await searchUseCase.findAll(query)
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.present(result, showsResults: !incremental)
                if let buffer { self?.presentSearchHighlights(result, query: query, buffer: buffer) }
            } catch SearchFailure.cancelled { }
            catch SearchFailure.noSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: "Select a non-empty range to search")
            }
            catch SearchFailure.invalidSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: "Selection changed; select a range again")
            }
            catch {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentFailure(prefix: "Search failed: %1$@", error: error)
            }
        }
    }

    private func routeBookmarkMatches(_ query: SearchQuery, clearPrevious: Bool) {
        guard workspaceInteractionsAreActionable, !query.pattern.isEmpty,
              let searchUseCase, let editor = actionableBookmarkEditor,
              let buffer = workspace.snapshot().activeBuffer else { return }
        let context = (activeEditor as? any EditorNavigationPort)?.navigationPosition?.contextID
        let operation = beginSearchOperation()
        searchPanel.presentStatus(key: "Searching…")
        searchTask = Task { [weak self] in
            defer { self?.finishSearchOperation(operation) }
            guard let self else { return }
            do {
                let result = try await searchUseCase.findAll(query)
                guard self.searchOperationID == operation else { return }
                guard self.workspaceInteractionsAreActionable,
                      self.workspace.snapshot().activeBuffer == buffer,
                      self.activeEditor === editor,
                      (self.activeEditor as? any EditorNavigationPort)?.navigationPosition?.contextID == context,
                      result.documents.allSatisfy({ document in
                          document.matches.allSatisfy { $0.bufferID == buffer.bufferID && $0.revision == buffer.revision }
                      }) else {
                    self.searchPanel.presentStatus(key: "Result is stale")
                    return
                }
                let lines = Set(result.documents.flatMap { $0.matches.map { $0.line - 1 } }).sorted()
                if clearPrevious { editor.clearBookmarks() }
                let count = editor.addBookmarks(on: lines)
                self.recoveryUseCase?.editorViewStateDidChange()
                self.searchPanel.present(result, showsResults: false)
                self.searchPanel.presentStatus(key: result.isTruncated
                    ? "Bookmarked %1$@ of %2$@ matching lines (results truncated)"
                    : "Bookmarked %1$@ of %2$@ matching lines", arguments: [String(count), String(lines.count)])
            } catch {
                guard self.searchOperationID == operation else { return }
                self.searchPanel.presentFailure(prefix: "Search failed: %1$@", error: error)
            }
        }
    }

    private func chooseSearchFolder() {
        guard let filePanels else { return }
        let operation = beginSearchOperation()
        searchTask = Task { [weak self] in
            defer { self?.finishSearchOperation(operation) }
            guard let self,
                  let root = await filePanels.chooseFolderURL(attachedTo: self.searchPanel.window),
                  self.searchOperationID == operation else { return }
            self.searchPanel.setFolderURL(root)
        }
    }

    private func routeFindInFolder(_ query: SearchQuery) {
        guard workspaceInteractionsAreActionable,
              !query.pattern.isEmpty,
              let folderSearchUseCase,
              let filePanels else { return }
        let operation = beginSearchOperation()
        searchPanel.presentStatus(key: "Choose a folder…")
        searchTask = Task { [weak self] in
            defer { self?.finishSearchOperation(operation) }
            guard let self,
                  let root = await self.searchFolderURL(using: filePanels),
                  self.searchOperationID == operation,
                  self.workspaceInteractionsAreActionable else { return }
            self.searchPanel.setFolderURL(root)
            self.searchPanel.presentStatus(key: "Searching %1$@…", arguments: [root.lastPathComponent])
            do {
                let result = try await folderSearchUseCase.search(rootPath: root.path, query: query)
                guard self.searchOperationID == operation else { return }
                self.searchPanel.present(result)
            } catch FolderSearchFailure.search(.cancelled) { }
            catch {
                guard self.searchOperationID == operation else { return }
                self.searchPanel.presentFailure(prefix: "Folder search failed: %1$@", error: error)
            }
        }
    }

    private func searchFolderURL(using panels: any FilePanelPresenting) async -> URL? {
        if let url = searchPanel.folderURL { return url }
        return await panels.chooseFolderURL(attachedTo: searchPanel.window)
    }

    private func routeReplace(_ query: SearchQuery) {
        guard workspaceInteractionsAreActionable,
              !query.pattern.isEmpty, let searchUseCase else { return }
        let operation = beginSearchOperation()
        searchTask = Task { [weak self] in
            defer { self?.finishSearchOperation(operation) }
            do {
                let next = try await searchUseCase.replaceCurrentThenFind(query)
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: next == nil ? "Replaced; no next match" : "Replaced")
            } catch SearchFailure.noSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: "Select a non-empty range to replace")
            }
            catch SearchFailure.invalidSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: "Selection changed; select a range again")
            }
            catch {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentFailure(prefix: "Replace failed: %1$@", error: error)
            }
        }
    }

    private func routeReplaceAll(_ query: SearchQuery) {
        guard workspaceInteractionsAreActionable,
              !query.pattern.isEmpty, let searchUseCase else { return }
        let operation = beginSearchOperation()
        searchTask = Task { [weak self] in
            defer { self?.finishSearchOperation(operation) }
            do {
                let count = try await searchUseCase.replaceAll(query)
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: "search.replaced", arguments: [count])
            } catch SearchFailure.noSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: "Select a non-empty range to replace")
            }
            catch SearchFailure.invalidSelection {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: "Selection changed; select a range again")
            }
            catch {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentFailure(prefix: "Replace All failed: %1$@", error: error)
            }
        }
    }

    private func routeActivateSearchMatch(_ match: SearchMatch) {
        guard workspaceInteractionsAreActionable, let searchUseCase else { return }
        let operation = beginSearchOperation()
        searchTask = Task { [weak self] in
            defer { self?.finishSearchOperation(operation) }
            do {
                try await searchUseCase.activate(match)
                guard self?.searchOperationID == operation else { return }
                self?.activeEditor.focus()
            } catch {
                guard self?.searchOperationID == operation else { return }
                self?.searchPanel.presentStatus(key: "Result is stale")
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
            defer {
                self.pendingFolderActivationTasks.removeValue(forKey: token)
                self.finishSearchOperation(operation)
            }
            let outcome = await fileUseCase.activateFolderSearchMatch(document: document, match: match)
            guard self.searchOperationID == operation,
                  self.workspaceInteractionsAreActionable else { return }
            switch outcome {
            case .activated:
                self.searchPanel.presentStatus(key: "Opened %1$@:%2$@", arguments: [document.relativePath, String(match.line)])
            case .stale:
                self.searchPanel.presentStatus(key: "Folder result changed; search again")
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

    private func highlightQueryKey(_ query: SearchQuery) -> SearchQuery {
        var key = query
        key.replacement = ""
        key.options.direction = .forward
        return key
    }

    private func hasSearchHighlights(for query: SearchQuery, buffer: EditorBufferDescriptor) -> Bool {
        highlightedSearch?.buffer == buffer && highlightedSearch?.query == highlightQueryKey(query)
    }

    private func presentSearchHighlights(_ result: SearchResultSet, query: SearchQuery, buffer: EditorBufferDescriptor) {
        guard !searchPanel.isHidden, workspace.snapshot().activeBuffer == buffer,
              let editor = activeEditor as? any SearchHighlightEditorPort else { return }
        editor.setSearchHighlights(result)
        highlightedSearch = (buffer, highlightQueryKey(query))
    }

    private func clearSearchHighlights() {
        highlightedSearch = nil
        (activeEditor as? any SearchHighlightEditorPort)?.clearSearchHighlights()
    }

    private func beginSearchOperation() -> UInt64 {
        searchTask?.cancel()
        searchOperationID &+= 1
        searchPanel.setSearchInProgress(true)
        return searchOperationID
    }

    private func finishSearchOperation(_ operation: UInt64) {
        guard searchOperationID == operation else { return }
        searchPanel.setSearchInProgress(false)
    }

    private func cancelSearch() {
        clearSearchHighlights()
        searchPanel.setSearchInProgress(false)
        searchTask?.cancel()
        searchTask = nil
        searchOperationID &+= 1
    }

    private func closeSearchPanel() {
        cancelSearch()
        searchWindowController.dismiss()
        window?.makeKeyAndOrderFront(nil)
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
        accessRecoveryContext: FileWorkspaceContext? = nil,
        conversion: TextFileConversion? = nil,
        savesCopy: Bool = false,
        retry: @escaping @MainActor () -> Void
    ) async -> FileSaveOutcome {
        var current = fileOutcome
        var offeredAccessRecovery = false
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
            case .failed(.store(.permissionDenied(let path))), .failed(.store(.notFound(let path))):
                guard !offeredAccessRecovery, let context = accessRecoveryContext,
                      let fileUseCase, let filePanels else {
                    if case .failed(let failure) = current {
                        fileConflictPresenter?.presentFileFailure(failure, attachedTo: window, retry: retry)
                    }
                    return current
                }
                offeredAccessRecovery = true
                guard !Task.isCancelled, !hasTornDownWindow,
                      workspace.activeFileContext() == context else { return .cancelled(context.tabID) }
                let selected = await filePanels.chooseSaveAccessURL(
                    for: URL(fileURLWithPath: path), attachedTo: window
                )
                guard let selected, !Task.isCancelled, !hasTornDownWindow,
                      workspace.activeFileContext() == context else { return .cancelled(context.tabID) }
                // Preserve the buffer and original observed identity: regranting
                // access must not reload edits or bypass external-change checks.
                if savesCopy {
                    current = await fileUseCase.saveCopy(selected, conversion: conversion,
                        expectedContext: context, renewingAccess: true)
                } else {
                    current = await fileUseCase.saveAs(selected, conversion: conversion,
                        expectedContext: context, renewingAccess: true)
                }
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
        guard let context = workspace.activeFileContext(), context.tabID == tabID else { return .cancelled }
        var outcome = await fileUseCase.saveActive(expectedContext: context)
        if case .requiresDestination = outcome {
            guard let url = await filePanels?.chooseSaveURL(suggestedName: context.title, attachedTo: window),
                  !Task.isCancelled, !hasTornDownWindow,
                  workspace.activeFileContext() == context else {
                return .cancelled
            }
            outcome = await fileUseCase.saveAs(url, expectedContext: context)
        }
        if case .failed(.workspace(let failure)) = outcome { return .workspaceFailure(failure) }
        let resolved = await resolve(fileOutcome: outcome, accessRecoveryContext: context) { [weak self] in
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

    private func renderEditorStatus() {
        statusBar.showLoading(fileUseCase?.loadingProgress ?? pendingWorkspaceFileReads.values.first)
        guard let status = (activeEditor as? any EditorStatusReportingPort)?.editorStatus else { return }
        let binding = workspace.activeFileContext()?.binding
        let binarySummary = binding?.binaryByteCount.map { count in
            ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
        }
        statusBar.apply(status, binarySummary: binarySummary)
    }

    @objc private func performToggleOvertype(_ sender: Any?) {
        guard workspaceInteractionsAreActionable else { return }
        (activeEditor as? any EditorStatusReportingPort)?.toggleOvertype()
        renderEditorStatus()
    }

    private func renderFileFormatStatus() {
        if workspace.activeFileContext()?.binding?.isReadOnly == true {
            setStatus(fileFormatStatus, text: L10n.text("Binary"), warning: false)
            statusBar.lineEndingButton.title = L10n.text("Read-only")
            statusBar.lineEndingButton.toolTip = L10n.text("Binary files are read-only and cannot be saved.")
            fileFormatStatus.toolTip = statusBar.lineEndingButton.toolTip
            fileFormatStatus.setAccessibilityValue(L10n.text("Read-only"))
            return
        }
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
        case .none where !hasFileBinding: ending = L10n.text("Unsaved")
        case .none: ending = L10n.text("No EOL")
        case .lf: ending = "LF"
        case .crlf: ending = "CRLF"
        case .cr: ending = "CR"
        case .mixed: ending = L10n.text("Mixed EOL")
        }
        setStatus(fileFormatStatus, text: encoding, warning: false)
        switch format.lineEnding {
        case .lf, .none: statusBar.lineEndingButton.title = "Unix (LF)"
        case .crlf: statusBar.lineEndingButton.title = "Windows (CRLF)"
        case .cr: statusBar.lineEndingButton.title = "Macintosh (CR)"
        case .mixed: statusBar.lineEndingButton.title = L10n.text("Mixed EOL")
        }
        statusBar.lineEndingButton.toolTip = L10n.text("Line endings: %1$@. Choose to convert and save.", L10n.argument(ending))
        fileFormatStatus.toolTip = L10n.text("Encoding: %1$@. Choose to reopen a file with another encoding or convert and save the displayed text.", L10n.argument(encoding))
        fileFormatStatus.setAccessibilityValue("\(encoding), \(ending)")
    }

    private func renderLanguageState(_ state: LanguageServiceState) {
        languageState = state
        switch state {
        case .ready(let detection, let fallback):
            let name = detection.languageID == .plainText ? L10n.text("Plain Text") : (languageUseCase?.registry[detection.languageID]?.displayName ?? detection.languageID.rawValue)
            let tier = languageUseCase?.registry[detection.languageID]?.supportTier
            let displayName = tier == .structural ? L10n.text("%1$@ · structural", name) : name
            setStatus(
                languageStatus,
                text: fallback ? L10n.text("%1$@ · styling paused (large file)", name) : displayName,
                warning: false
            )
        case .unavailableManual(let requestedID, let fallbackID):
            let fallbackName = fallbackID == .plainText ? L10n.text("Plain Text") : (languageUseCase?.registry[fallbackID]?.displayName ?? fallbackID.rawValue)
            setStatus(
                languageStatus,
                text: L10n.text("Unavailable language: %1$@ · using %2$@", L10n.argument(requestedID.rawValue), L10n.argument(fallbackName)),
                warning: true
            )
        case .degraded(let reason):
            setStatus(languageStatus, text: L10n.text("Plain Text · %1$@", L10n.argument(reason)), warning: true)
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
        displayedExtensionError = nil
        extensionState = state; extensionsPanel.render(state)
        let enabled = state.items.filter(\.enabled).count
        if !state.discoveryFailures.isEmpty {
            setStatus(
                extensionStatus,
                text: L10n.text("Extensions: %1$@ enabled · %2$@ issue(s)", L10n.argument(enabled), L10n.argument(state.discoveryFailures.count)),
                warning: true
            )
        } else {
            setStatus(
                extensionStatus,
                text: state.operationStatus ?? L10n.text("Extensions: %1$@ enabled", L10n.argument(enabled)),
                warning: false
            )
        }
        onExtensionCommandsChanged?()
    }

    private func renderExtensionError(_ error: any Error) {
        displayedExtensionError = error
        setStatus(extensionStatus, text: L10n.text("Extension error: %1$@", PresentationErrorText.message(error)), warning: true)
    }

    private func reviewCapabilities(for item: ExtensionRegistryItem, allow: Bool) {
        guard let window else { return }
        if !allow, item.issue == .untrustedPublisher {
            let alert = NSAlert(); alert.messageText = L10n.text("Reset publisher revocation?")
            alert.informativeText = L10n.text("This removes the durable publisher tombstone for %1$@ (%2$@). The extension remains disabled and receives no access until you explicitly enable it and approve a new identity-bound capability review.", L10n.argument(item.manifest.publisher.id), L10n.argument(item.publisherFingerprint))
            alert.addButton(withTitle: L10n.text("Reset Revocation")); alert.addButton(withTitle: L10n.text("Cancel"))
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
            ? L10n.text("Grant capabilities to %1$@?", L10n.argument(item.manifest.name))
            : L10n.text("Revoke publisher %1$@ across %2$@ extension(s)?", L10n.argument(item.manifest.publisher.id), L10n.argument(revocationToken?.affectedPackageIdentities.count ?? 0))
        alert.informativeText = extensionReviewDisclosure(for: item.manifest.id, revoking: !allow) ?? L10n.text("Extension identity unavailable; cancel and refresh.")
        alert.addButton(withTitle: allow ? L10n.text("Grant Exact Capabilities") : L10n.text("Revoke Publisher"))
        alert.addButton(withTitle: L10n.text("Cancel"))
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
