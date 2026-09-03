import AppKit
import DuckpadApplication
import DuckpadDomain

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

public struct ExtensionStatusSmokeState: Equatable, Sendable {
    public let text: String
    public let isWarning: Bool
    public let commandCount: Int
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
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
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
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
        isHidden = false
    }

    @objc private func retryPressed() {
        isHidden = true
        retryAction?()
    }
}

@MainActor
public final class DuckpadWindowController: NSWindowController, NSWindowDelegate {
    private let workspace: ScratchWorkspaceUseCase
    let tabStrip = MultilineTabStripView(frame: .zero)
    private let fallbackEditor: TextViewEditorAdapter?
    var editor: TextViewEditorAdapter {
        precondition(fallbackEditor != nil, "NSTextView adapter is not active in production composition")
        return fallbackEditor!
    }
    private let activeEditor: any EditorPort
    private let searchPanel = SearchPanelView(frame: .zero)
    private let languageStatus = NSTextField(labelWithString: "Plain Text")
    private let extensionStatus = NSTextField(labelWithString: "Extensions loading…")
    private let extensionsPanel = ExtensionsManagerPanel()
    private var searchUseCase: SearchWorkspaceUseCase?
    private var languageUseCase: LanguageWorkspaceUseCase?
    private var extensionUseCase: ExtensionWorkspaceUseCase?
    private var extensionState = ExtensionRegistryState(items: [])
    public var onExtensionCommandsChanged: (() -> Void)?
    private let editorHostView: NSView
    private let fileUseCase: FileDocumentUseCase?
    private let filePanels: (any FilePanelPresenting)?
    private let fileConflictPresenter: (any FileConflictPresenting)?
    private let dirtyDecisionPresenter: (any DirtyDocumentDecisionPresenting)?
    private let pathActionHandler: any TabPathActionHandling
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
    private var appliedThemePalette: EditorThemePalette?
    private var terminationReviewInProgress = false

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
        recoveryUseCase: SessionRecoveryUseCase? = nil,
        terminationCoordinator: ApplicationTerminationCoordinator? = nil,
        searchUseCase: SearchWorkspaceUseCase? = nil,
        languageUseCase: LanguageWorkspaceUseCase? = nil,
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
        self.recoveryUseCase = recoveryUseCase
        self.searchUseCase = searchUseCase
        self.languageUseCase = languageUseCase
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
        terminationCoordinator?.attach(windowController: self)
        window.delegate = self
        self.errorPresenter = configureContent(injectedPresenter: errorPresenter)
        editorBinding = EditorBindingUseCase(workspace: workspace, editor: activeEditor)
        tabStrip.onAdd = { [weak self] in self?.performAdd() }
        tabStrip.onActivate = { [weak self] id in self?.performActivate(id) }
        tabStrip.onClose = { [weak self] id in self?.performClose(id) }
        tabStrip.onMove = { [weak self] id, index in self?.performMove(id, to: index) }
        tabStrip.onContextAction = { [weak self] id, action in self?.performContextAction(action, for: id) }
        searchPanel.onFind = { [weak self] query in self?.routeFind(query) }
        searchPanel.onReplace = { [weak self] query in self?.routeReplace(query) }
        searchPanel.onReplaceAll = { [weak self] query in self?.routeReplaceAll(query) }
        searchPanel.onFindAll = { [weak self] query in self?.routeFindAll(query) }
        searchPanel.onIncrementalQuery = { [weak self] query in self?.routeFindAll(query, incremental: true) }
        searchPanel.onQueryInvalidated = { [weak self] in self?.cancelSearch() }
        searchPanel.onActivateMatch = { [weak self] match in self?.routeActivateSearchMatch(match) }
        searchPanel.onCancel = { [weak self] in self?.cancelSearch() }
        searchPanel.onClose = { [weak self] in self?.closeSearchPanel() }
        workspace.onChange = { [weak self] change in self?.handle(change) }
        languageUseCase?.onStateChange = { [weak self] state in self?.renderLanguageState(state) }
        extensionUseCase?.onStateChange = { [weak self] state in self?.renderExtensionState(state) }
        extensionsPanel.onSetEnabled = { [weak self] id, enabled in
            Task { @MainActor [weak self] in
                do { try await self?.extensionUseCase?.setEnabled(id, enabled: enabled) }
                catch { self?.renderExtensionError(error) }
            }
        }
        extensionsPanel.onGrantRequested = { [weak self] item in self?.reviewCapabilities(for: item, allow: true) }
        extensionsPanel.onRevoke = { [weak self] item in self?.reviewCapabilities(for: item, allow: false) }
        renderInitial(workspace.snapshot())
        if automaticallyStarts { start() }
    }

    deinit {
        startTask?.cancel()
        searchTask?.cancel()
        languageDetectionTask?.cancel()
    }

    public override func close() {
        window?.delegate = nil
        workspace.onChange = nil
        activeEditor.onEdit = nil
        languageUseCase?.onStateChange = nil
        extensionUseCase?.onStateChange = nil
        editorBinding = nil
        errorPresenter = nil
        tabStrip.tearDownHostedViews()
        let closingWindow = window
        closingWindow?.contentViewController = nil
        closingWindow?.windowController = nil
        super.close()
        window = nil
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
            text: languageStatus.stringValue,
            isWarning: languageStatus.textColor == .systemOrange
        )
    }

    public func extensionStatusSmokeState() -> ExtensionStatusSmokeState {
        ExtensionStatusSmokeState(text: extensionStatus.stringValue, isWarning: extensionStatus.textColor == .systemOrange,
                                  commandCount: extensionCommands.count)
    }

    public func extensionReviewDisclosure(for id: ExtensionID, revoking: Bool) -> String? {
        guard let item = extensionState.items.first(where: { $0.manifest.id == id }) else { return nil }
        let requested = item.manifest.capabilities.map { "\($0.id.rawValue) [\($0.scope.rawValue)]" }.joined(separator: "\n")
        let affected = (try? extensionUseCase?.revocationReviewToken(for: id).affectedPackageIdentities.joined(separator: "\n"))
            ?? "\(item.manifest.id.rawValue)@\(item.manifest.version)#\(item.packageDigest)"
        return "Publisher: \(item.manifest.publisher.id)\nFingerprint: \(item.publisherFingerprint)\nVersion: \(item.manifest.version)\nPackage: \(item.packageDigest)\n\nData access and destination:\n\(requested)\n\nAffected signed package identities:\n\(affected)\n\nGrants last until revoked or identity changes. Publisher revoke is durable across restart until deliberate Reset. No network, filesystem, environment, clock, or process access is exposed."
    }

    public var extensionCommands: [ExtensionCommandContribution] {
        extensionState.items.filter { item in
            guard item.enabled, item.issue == nil else { return false }
            let grants = item.granted
            return item.manifest.contributes.commands.contains { command in
                let scope: ExtensionCapabilityScope = command.inputScope == .selection ? .selection : .activeDocument
                return grants.contains(.init(id: .documentsRead, scope: scope)) &&
                    grants.contains(.init(id: .documentsWrite, scope: scope))
            }
        }.flatMap { item in
            item.manifest.contributes.commands.filter { command in
                let scope: ExtensionCapabilityScope = command.inputScope == .selection ? .selection : .activeDocument
                return item.granted.contains(.init(id: .documentsRead, scope: scope)) &&
                    item.granted.contains(.init(id: .documentsWrite, scope: scope))
            }
        }.sorted { $0.title < $1.title }
    }

    @objc public func performShowExtensions(_ sender: Any?) { extensionsPanel.show(relativeTo: window) }

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
        Task { @MainActor [weak self] in _ = await self?.languageUseCase?.setOverride(.automatic) }
    }

    @objc public func performChooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        Task { @MainActor [weak self] in
            _ = await self?.languageUseCase?.setOverride(.manual(LanguageID(rawValue: raw)))
        }
    }

    @objc public func performToggleLineComment(_ sender: Any?) { _ = languageUseCase?.toggleLineComment() }

    @objc public func performShowLanguageChooser(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Choose Language"
        alert.informativeText = "Use the Language menu to choose from \(languageDefinitions.count) bundled languages."
        alert.beginSheetModal(for: window)
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
            await extensionUseCase?.refresh()
        }
    }

    public func waitForStartup() async { await startTask?.value }

    func performAdd() {
        Task { [weak workspace] in _ = await workspace?.addScratch() }
    }

    func performActivate(_ id: TabID) {
        Task { [weak workspace] in _ = await workspace?.activate(tabID: id) }
    }

    func performClose(_ id: TabID, decision: CloseDecision? = nil) {
        Task { [weak self] in await self?.requestClose(tabID: id, decision: decision) }
    }

    @objc public func performCloseActiveTab(_ sender: Any? = nil) {
        guard let id = workspace.snapshot().tabs.first(where: \.isActive)?.id else { return }
        performClose(id)
    }

    @objc public func performNextTab(_ sender: Any? = nil) {
        Task { [weak workspace] in _ = await workspace?.navigateTabs(.next) }
    }

    @objc public func performPreviousTab(_ sender: Any? = nil) {
        Task { [weak workspace] in _ = await workspace?.navigateTabs(.previous) }
    }

    @objc public func performLastUsedTab(_ sender: Any? = nil) {
        Task { [weak workspace] in _ = await workspace?.navigateTabs(.lastUsed) }
    }

    @objc public func performMoveActiveTabLeft(_ sender: Any? = nil) {
        Task { [weak workspace] in _ = await workspace?.moveActiveTab(by: -1) }
    }

    @objc public func performMoveActiveTabRight(_ sender: Any? = nil) {
        Task { [weak workspace] in _ = await workspace?.moveActiveTab(by: 1) }
    }

    @objc public func performOpenFile(_ sender: Any? = nil) {
        Task { [weak self] in await self?.routeOpenFile() }
    }

    @objc public func performSaveFile(_ sender: Any? = nil) {
        Task { [weak self] in await self?.routeSaveFile() }
    }

    @objc public func performSaveFileAs(_ sender: Any? = nil) {
        Task { [weak self] in await self?.routeSaveFileAs() }
    }

    @objc public func performShowFind(_ sender: Any? = nil) { searchPanel.show(replace: false) }
    @objc public func performShowReplace(_ sender: Any? = nil) { searchPanel.show(replace: true) }
    @objc public func performFindNext(_ sender: Any? = nil) {
        if searchPanel.isHidden { searchPanel.show(replace: false); return }
        routeFind(searchPanel.currentQuery())
    }
    @objc public func performFindPrevious(_ sender: Any? = nil) {
        if searchPanel.isHidden { searchPanel.show(replace: false); return }
        routeFind(searchPanel.currentQuery(direction: .backward))
    }
    @objc public func performCloseFindPanel(_ sender: Any? = nil) {
        closeSearchPanel()
    }

    public func routeOpenFile() async {
        guard let fileUseCase, let url = await filePanels?.chooseOpenURL(attachedTo: window) else { return }
        await handle(fileOutcome: await fileUseCase.open(url)) { [weak self] in
            Task { @MainActor [weak self] in await self?.routeOpenFile() }
        }
    }

    public func routeSaveFile() async {
        guard let fileUseCase else { return }
        let outcome = await fileUseCase.saveActive()
        if case .requiresDestination = outcome {
            await routeSaveFileAs()
        } else {
            _ = await resolve(fileOutcome: outcome) { [weak self] in
                Task { @MainActor [weak self] in await self?.routeSaveFile() }
            }
        }
    }

    public func routeSaveFileAs() async {
        guard let fileUseCase, let context = workspace.activeFileContext(),
              let url = await filePanels?.chooseSaveURL(suggestedName: context.title, attachedTo: window) else { return }
        _ = await resolve(fileOutcome: await fileUseCase.saveAs(url)) { [weak self] in
            Task { @MainActor [weak self] in await self?.routeSaveFileAs() }
        }
    }

    public var hasDirtyDocuments: Bool {
        workspace.snapshot().tabs.contains(where: \.isDirty)
    }

    public var requiresTerminationReview: Bool {
        hasDirtyDocuments || recoveryUseCase != nil || extensionUseCase != nil
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
        guard !terminationReviewInProgress else { return false }
        terminationReviewInProgress = true
        activeEditor.setInputEnabled(false)
        var approved = false
        defer {
            terminationReviewInProgress = false
            if !approved {
                extensionUseCase?.resumeInvocations()
                activeEditor.setInputEnabled(true)
            }
        }
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

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if permitsNextWindowClose {
            permitsNextWindowClose = false
            return true
        }
        guard requiresTerminationReview else { return true }
        guard let terminationCoordinator else { return false }
        terminationCoordinator.requestWindowClose { [weak self, weak sender] approved in
            guard let self else { return }
            guard approved, let sender else { return }
            self.permitsNextWindowClose = true
            self.approvedWindowClose(sender)
        }
        return false
    }

    public func windowDidResignKey(_ notification: Notification) {
        Task { [weak self] in _ = await self?.flushRecovery() }
    }

    private func configureContent(
        injectedPresenter: (any PersistenceErrorPresenting)?
    ) -> any PersistenceErrorPresenting {
        let root = NSViewController()
        let dropView = FileDropView()
        dropView.onFiles = { [weak self] urls in
            guard let self, let fileUseCase = self.fileUseCase else { return }
            Task { @MainActor in
                for url in urls {
                    await self.handle(fileOutcome: await fileUseCase.open(url)) { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, let fileUseCase = self.fileUseCase else { return }
                            await self.handle(fileOutcome: await fileUseCase.open(url)) {}
                        }
                    }
                }
            }
        }
        root.view = dropView
        let banner = PersistenceErrorBanner(frame: .zero)
        root.view.addSubview(banner)
        root.view.addSubview(tabStrip)
        root.view.addSubview(searchPanel)
        root.view.addSubview(editorHostView)
        languageStatus.translatesAutoresizingMaskIntoConstraints = false
        languageStatus.font = .systemFont(ofSize: 11)
        languageStatus.textColor = .secondaryLabelColor
        languageStatus.alignment = .right
        languageStatus.setAccessibilityIdentifier("duckpad.language.status")
        root.view.addSubview(languageStatus)
        extensionStatus.translatesAutoresizingMaskIntoConstraints = false
        extensionStatus.font = .systemFont(ofSize: 11)
        extensionStatus.textColor = .secondaryLabelColor
        extensionStatus.setAccessibilityIdentifier("duckpad.extensions.status")
        root.view.addSubview(extensionStatus)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            banner.topAnchor.constraint(equalTo: root.view.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: banner.bottomAnchor),
            searchPanel.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            searchPanel.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            searchPanel.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            editorHostView.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            editorHostView.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            editorHostView.topAnchor.constraint(equalTo: searchPanel.bottomAnchor),
            editorHostView.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            languageStatus.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -10),
            languageStatus.bottomAnchor.constraint(equalTo: root.view.bottomAnchor, constant: -5),
            extensionStatus.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: 10),
            extensionStatus.bottomAnchor.constraint(equalTo: root.view.bottomAnchor, constant: -5),
        ])
        window?.contentViewController = root
        return injectedPresenter ?? banner
    }

    private func renderInitial(_ snapshot: WorkspaceSnapshot) {
        tabStrip.apply(tabs: snapshot.tabs)
        let enabled = snapshot.startup == .ready
        tabStrip.setInteractionsEnabled(enabled)
        editorBinding.render(snapshot)
        updateWindowTitle(snapshot)
    }

    private func handle(_ change: WorkspaceChange) {
        tabStrip.apply(change: change)
        tabStrip.setInteractionsEnabled(change.snapshot.startup == .ready)
        let firstLanguageValidation = change.snapshot.startup == .ready && !languageValidated
        var registryReady = true
        if firstLanguageValidation {
            languageValidated = true
            registryReady = languageUseCase?.validateRegistry() ?? false
        }
        editorBinding.render(change)
        updateWindowTitle(change.snapshot)
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

    private func shouldRefreshLanguage(for change: WorkspaceChange) -> Bool {
        switch change.kind {
        case .reset, .tabInserted, .activeTabChanged, .tabRemoved:
            return true
        case .tabUpdated(let index):
            return change.snapshot.tabs.indices.contains(index) && change.snapshot.tabs[index].isActive
        case .bufferEdited, .persistence, .tabsReordered:
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

    private func requestClose(tabID: TabID, decision forcedDecision: CloseDecision?) async {
        await requestClose(
            tabIDs: [tabID],
            retryingSaveTabID: nil,
            forcedDecision: forcedDecision
        )
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
        if case .failed(let failure) = outcome { presentCloseFailure(failure) }
    }

    private func requestClose(scope: TabCloseScope, relativeTo tabID: TabID) async {
        let targets = workspace.tabIDs(for: scope, relativeTo: tabID)
        await requestClose(
            tabIDs: targets,
            retryingSaveTabID: nil
        )
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
        Task { [weak workspace] in _ = await workspace?.moveTab(tabID, to: index) }
    }

    private func performContextAction(_ action: TabContextAction, for tabID: TabID) {
        switch action {
        case .close(let scope):
            Task { [weak self] in await self?.requestClose(scope: scope, relativeTo: tabID) }
        case .setPinned(let pinned):
            Task { [weak workspace] in _ = await workspace?.setPinned(tabID, isPinned: pinned) }
        case .copyFullPath:
            guard let path = workspace.snapshot().tabs.first(where: { $0.id == tabID })?.fullPath else { return }
            pathActionHandler.copyFullPath(path)
        case .openContainingFolder:
            guard let path = workspace.snapshot().tabs.first(where: { $0.id == tabID })?.fullPath else { return }
            pathActionHandler.openContainingFolder(for: path)
        }
    }

    private func routeFind(_ query: SearchQuery) {
        guard !query.pattern.isEmpty, let searchUseCase else { return }
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
        guard !query.pattern.isEmpty, let searchUseCase else { return }
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

    private func routeReplace(_ query: SearchQuery) {
        guard !query.pattern.isEmpty, let searchUseCase else { return }
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
        guard !query.pattern.isEmpty, let searchUseCase else { return }
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
        guard let searchUseCase else { return }
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
        switch fileOutcome {
        case .conflict:
            guard let fileUseCase, let presenter = fileConflictPresenter else { return fileOutcome }
            let resolution = await presenter.resolveExternalConflict(attachedTo: window)
            return await resolve(fileOutcome: await fileUseCase.resolveConflict(resolution), retry: retry)
        case .failed(.workspace):
            break
        case .failed(let failure):
            fileConflictPresenter?.presentFileFailure(failure, attachedTo: window, retry: retry)
        case .saved, .requiresDestination, .cancelled:
            break
        }
        return fileOutcome
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

    private func renderLanguageState(_ state: LanguageServiceState) {
        switch state {
        case .ready(let detection, let fallback):
            let name = languageUseCase?.registry[detection.languageID]?.displayName ?? detection.languageID.rawValue
            let tier = languageUseCase?.registry[detection.languageID]?.supportTier
            let suffix = tier == .structural ? " · structural" : ""
            languageStatus.stringValue = fallback ? "\(name) · styling paused (large file)" : name + suffix
            languageStatus.textColor = .secondaryLabelColor
        case .unavailableManual(let requestedID, let fallbackID):
            let fallbackName = languageUseCase?.registry[fallbackID]?.displayName ?? fallbackID.rawValue
            languageStatus.stringValue = "Unavailable language: \(requestedID.rawValue) · using \(fallbackName)"
            languageStatus.textColor = .systemOrange
        case .degraded(let reason):
            languageStatus.stringValue = "Plain Text · \(reason)"
            languageStatus.textColor = .systemOrange
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
            extensionStatus.stringValue = "Extensions: \(enabled) enabled · \(state.discoveryFailures.count) issue(s)"
            extensionStatus.textColor = .systemOrange
        } else {
            extensionStatus.stringValue = state.operationStatus ?? "Extensions: \(enabled) enabled"
            extensionStatus.textColor = .secondaryLabelColor
        }
        onExtensionCommandsChanged?()
    }

    private func renderExtensionError(_ error: any Error) {
        extensionStatus.stringValue = "Extension error: \(error)"; extensionStatus.textColor = .systemOrange
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
