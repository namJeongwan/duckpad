import AppKit
import DuckpadApplication
import DuckpadDomain

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
public final class DuckpadWindowController: NSWindowController {
    private let workspace: ScratchWorkspaceUseCase
    let tabStrip = MultilineTabStripView(frame: .zero)
    let editor = TextViewEditorAdapter()
    private var editorBinding: EditorBindingUseCase!
    private var errorPresenter: (any PersistenceErrorPresenting)!
    private var handledFailureIDs: Set<UUID> = []
    private var startTask: Task<Void, Never>?

    public init(
        workspace: ScratchWorkspaceUseCase,
        errorPresenter: (any PersistenceErrorPresenting)? = nil,
        automaticallyStarts: Bool = true
    ) {
        self.workspace = workspace
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
        self.errorPresenter = configureContent(injectedPresenter: errorPresenter)
        editorBinding = EditorBindingUseCase(workspace: workspace, editor: editor)
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
        workspace.onChange = nil
        editor.onEdit = nil
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
        startTask = Task { [weak workspace] in _ = await workspace?.start() }
    }

    func waitForStartup() async { await startTask?.value }

    func performAdd() {
        Task { [weak workspace] in _ = await workspace?.addScratch() }
    }

    func performActivate(_ id: TabID) {
        Task { [weak workspace] in _ = await workspace?.activate(tabID: id) }
    }

    func performClose(_ id: TabID, decision: CloseDecision? = nil) {
        Task { [weak self] in await self?.requestClose(tabID: id, decision: decision) }
    }

    private func configureContent(
        injectedPresenter: (any PersistenceErrorPresenting)?
    ) -> any PersistenceErrorPresenting {
        let root = NSViewController()
        root.view = NSView()
        let banner = PersistenceErrorBanner(frame: .zero)
        root.view.addSubview(banner)
        root.view.addSubview(tabStrip)
        root.view.addSubview(editor.scrollView)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            banner.topAnchor.constraint(equalTo: root.view.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: banner.bottomAnchor),
            editor.scrollView.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            editor.scrollView.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            editor.scrollView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            editor.scrollView.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
        ])
        window?.contentViewController = root
        return injectedPresenter ?? banner
    }

    private func renderInitial(_ snapshot: WorkspaceSnapshot) {
        tabStrip.apply(tabs: snapshot.tabs)
        let enabled = snapshot.startup == .ready
        tabStrip.setInteractionsEnabled(enabled)
        editorBinding.render(snapshot)
    }

    private func handle(_ change: WorkspaceChange) {
        tabStrip.apply(change: change)
        tabStrip.setInteractionsEnabled(change.snapshot.startup == .ready)
        editorBinding.render(change)
        guard let event = change.failureEvent, handledFailureIDs.insert(event.id).inserted else { return }
        errorPresenter.present(failure: event.failure) { [weak self] in
            guard let self else { return }
            Task { [weak workspace] in _ = await workspace?.retry(event.retry) }
        }
    }

    private func requestClose(tabID: TabID, decision: CloseDecision?) async {
        switch await workspace.close(tabID: tabID, decision: decision) {
        case .requiresDecision:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Discard changes to this scratch tab?"
            alert.informativeText = "Saving to a file is not available yet. Cancel keeps the live editor buffer."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            let chosen: CloseDecision = alert.runModal() == .alertFirstButtonReturn ? .discard : .cancel
            _ = await workspace.close(tabID: tabID, decision: chosen)
        case .saveUnavailable:
            let failure = PersistenceFailure(operation: .save, cause: .unavailable("File save is not implemented in Phase 1"))
            errorPresenter.present(failure: failure) {}
        case .cancelled, .closed, .rejected, .persistenceFailed:
            break
        }
    }
}
