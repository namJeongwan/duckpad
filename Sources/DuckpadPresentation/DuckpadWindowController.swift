import AppKit
import DuckpadApplication
import DuckpadDomain

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
    private let editorHostView: NSView
    private let fileUseCase: FileDocumentUseCase?
    private let filePanels: (any FilePanelPresenting)?
    private let fileConflictPresenter: (any FileConflictPresenting)?
    private let dirtyDecisionPresenter: (any DirtyDocumentDecisionPresenting)?
    private let recoveryUseCase: SessionRecoveryUseCase?
    let terminationCoordinator: ApplicationTerminationCoordinator?
    private let approvedWindowClose: @MainActor (NSWindow) -> Void
    private var editorBinding: EditorBindingUseCase!
    private var errorPresenter: (any PersistenceErrorPresenting)!
    private var handledFailureIDs: Set<UUID> = []
    private var startTask: Task<Void, Never>?
    private var permitsNextWindowClose = false

    public init(
        workspace: ScratchWorkspaceUseCase,
        editorAdapter: (any EditorPort)? = nil,
        editorView: NSView? = nil,
        errorPresenter: (any PersistenceErrorPresenting)? = nil,
        fileUseCase: FileDocumentUseCase? = nil,
        filePanels: (any FilePanelPresenting)? = nil,
        fileConflictPresenter: (any FileConflictPresenting)? = nil,
        dirtyDecisionPresenter: (any DirtyDocumentDecisionPresenting)? = nil,
        recoveryUseCase: SessionRecoveryUseCase? = nil,
        terminationCoordinator: ApplicationTerminationCoordinator? = nil,
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
        self.recoveryUseCase = recoveryUseCase
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
        workspace.onChange = { [weak self] change in self?.handle(change) }
        renderInitial(workspace.snapshot())
        if automaticallyStarts { start() }
    }

    deinit {
        startTask?.cancel()
    }

    public override func close() {
        window?.delegate = nil
        workspace.onChange = nil
        activeEditor.onEdit = nil
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

    @objc public func performOpenFile(_ sender: Any? = nil) {
        Task { [weak self] in await self?.routeOpenFile() }
    }

    @objc public func performSaveFile(_ sender: Any? = nil) {
        Task { [weak self] in await self?.routeSaveFile() }
    }

    @objc public func performSaveFileAs(_ sender: Any? = nil) {
        Task { [weak self] in await self?.routeSaveFileAs() }
    }

    public func routeOpenFile() async {
        guard let fileUseCase, let url = await filePanels?.chooseOpenURL(attachedTo: window) else { return }
        await handle(fileOutcome: await fileUseCase.open(url))
    }

    public func routeSaveFile() async {
        guard let fileUseCase else { return }
        let outcome = await fileUseCase.saveActive()
        if case .requiresDestination = outcome {
            await routeSaveFileAs()
        } else {
            _ = await resolve(fileOutcome: outcome)
        }
    }

    public func routeSaveFileAs() async {
        guard let fileUseCase, let context = workspace.activeFileContext(),
              let url = await filePanels?.chooseSaveURL(suggestedName: context.title, attachedTo: window) else { return }
        _ = await resolve(fileOutcome: await fileUseCase.saveAs(url))
    }

    public var hasDirtyDocuments: Bool {
        workspace.snapshot().tabs.contains(where: \.isDirty)
    }

    public var requiresTerminationReview: Bool { hasDirtyDocuments || recoveryUseCase != nil }

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
        while let tab = workspace.snapshot().tabs.first(where: \.isDirty) {
            guard let presenter = dirtyDecisionPresenter else { return false }
            let decision = await presenter.decision(
                for: tab,
                saveAvailable: fileUseCase != nil,
                attachedTo: window
            )
            switch decision {
            case .cancel:
                return false
            case .discard:
                guard case .closed = await workspace.close(tabID: tab.id, decision: .discard) else {
                    return false
                }
            case .save:
                guard await saveBeforeClosing(tabID: tab.id) else { return false }
            }
        }
        return await flushRecovery(final: true)
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
                for url in urls { await self.handle(fileOutcome: await fileUseCase.open(url)) }
            }
        }
        root.view = dropView
        let banner = PersistenceErrorBanner(frame: .zero)
        root.view.addSubview(banner)
        root.view.addSubview(tabStrip)
        root.view.addSubview(editorHostView)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            banner.topAnchor.constraint(equalTo: root.view.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: banner.bottomAnchor),
            editorHostView.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            editorHostView.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            editorHostView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            editorHostView.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
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
        editorBinding.render(change)
        updateWindowTitle(change.snapshot)
        recoveryUseCase?.workspaceDidChange(change)
        guard let event = change.failureEvent, handledFailureIDs.insert(event.id).inserted else { return }
        errorPresenter.present(failure: event.failure) { [weak self] in
            guard let self else { return }
            Task { [weak workspace] in _ = await workspace?.retry(event.retry) }
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

    private func requestClose(tabID: TabID, decision: CloseDecision?) async {
        switch await workspace.close(tabID: tabID, decision: decision) {
        case .requiresDecision:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Save changes before closing?"
            alert.informativeText = "Save writes the live editor buffer. Discard closes it without writing."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if await saveBeforeClosing(tabID: tabID) { _ = await workspace.close(tabID: tabID) }
            case .alertThirdButtonReturn:
                _ = await workspace.close(tabID: tabID, decision: .discard)
            default:
                break
            }
        case .saveUnavailable:
            let failure = PersistenceFailure(operation: .save, cause: .unavailable("File save is not implemented in Phase 1"))
            errorPresenter.present(failure: failure) {}
        case .cancelled, .closed, .rejected, .persistenceFailed:
            break
        }
    }

    private func handle(fileOutcome: FileOpenOutcome) async {
        if case .failed(let failure) = fileOutcome {
            fileConflictPresenter?.presentFileFailure(failure, attachedTo: window)
        }
    }

    @discardableResult
    private func resolve(fileOutcome: FileSaveOutcome) async -> FileSaveOutcome {
        switch fileOutcome {
        case .conflict:
            guard let fileUseCase, let presenter = fileConflictPresenter else { return fileOutcome }
            let resolution = await presenter.resolveExternalConflict(attachedTo: window)
            return await resolve(fileOutcome: await fileUseCase.resolveConflict(resolution))
        case .failed(let failure):
            fileConflictPresenter?.presentFileFailure(failure, attachedTo: window)
        case .saved, .requiresDestination, .cancelled:
            break
        }
        return fileOutcome
    }

    private func saveBeforeClosing(tabID: TabID) async -> Bool {
        guard let fileUseCase else { return false }
        if workspace.snapshot().tabs.first(where: \.isActive)?.id != tabID {
            guard case .applied = await workspace.activate(tabID: tabID) else { return false }
        }
        var outcome = await fileUseCase.saveActive()
        if case .requiresDestination = outcome {
            guard let context = workspace.activeFileContext(),
                  let url = await filePanels?.chooseSaveURL(suggestedName: context.title, attachedTo: window) else { return false }
            outcome = await fileUseCase.saveAs(url)
        }
        if case .saved = await resolve(fileOutcome: outcome) { return true }
        return false
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
}
