import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
final class WorkspaceBarView: NSView {
    enum Edge { case top, bottom }

    private let separator = CALayer()
    private let edge: Edge

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(separator)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let thickness = 1 / scale
        let y = edge == .top ? bounds.height - thickness : 0
        separator.frame = NSRect(x: 0, y: y, width: bounds.width, height: thickness)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        separator.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.72).cgColor
    }
}

@MainActor
final class DocumentSwitcherButton: NSButton {
    struct UpdateMetrics: Equatable {
        fileprivate(set) var fullRebuilds = 0
        fileprivate(set) var itemUpdates = 0
        fileprivate(set) var incrementalItemInspections = 0
    }

    var onActivate: ((TabID) -> Void)?
    private(set) var updateMetrics = UpdateMetrics()
    private(set) var tabs: [TabSnapshot] = []
    let documentPanel = DocumentSwitcherPanel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(showDocuments)
        bezelStyle = .roundRect
        controlSize = .small
        isBordered = true
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Show All Documents")
        imagePosition = .imageTrailing
        imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: 11, weight: .medium)
        contentTintColor = .secondaryLabelColor
        toolTip = "Open Documents"
        setAccessibilityIdentifier("duckpad.tab.documents")
        setAccessibilityLabel("Open Documents")
        translatesAutoresizingMaskIntoConstraints = false
        documentPanel.onActivate = { [weak self] id in
            guard self?.isEnabled == true else { return }
            self?.onActivate?(id)
        }
        updateButtonLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(tabs: [TabSnapshot]) {
        self.tabs = tabs
        if documentPanel.isPresented { documentPanel.apply(tabs: tabs) }
        updateButtonLabel()
        setInteractionsEnabled(isEnabled)
        updateMetrics.fullRebuilds += 1
    }

    func apply(change: WorkspaceChange) {
        switch change.kind {
        case .persistence:
            guard tabs.count == change.snapshot.tabs.count else { return apply(tabs: change.snapshot.tabs) }
        case .tabUpdated(let index), .bufferEdited(let index):
            guard tabs.count == change.snapshot.tabs.count,
                  tabs.indices.contains(index) else {
                apply(tabs: change.snapshot.tabs)
                return
            }
            tabs[index] = change.snapshot.tabs[index]
            updateMetrics.itemUpdates += 1
            updateMetrics.incrementalItemInspections += 1
        case .activeTabChanged(let previousIndex, let currentIndex):
            let affected = [previousIndex, currentIndex]
                .compactMap { $0 }
                .reduce(into: [Int]()) { indices, index in
                    if !indices.contains(index) { indices.append(index) }
            }
            guard tabs.count == change.snapshot.tabs.count,
                  !affected.isEmpty,
                  affected.allSatisfy({ tabs.indices.contains($0) }) else {
                apply(tabs: change.snapshot.tabs)
                return
            }
            for index in affected {
                tabs[index] = change.snapshot.tabs[index]
            }
            updateMetrics.itemUpdates += affected.count
            updateMetrics.incrementalItemInspections += affected.count
        default:
            return apply(tabs: change.snapshot.tabs)
        }
        if documentPanel.isPresented { documentPanel.apply(tabs: tabs) }
        updateButtonLabel()
    }

    func setInteractionsEnabled(_ enabled: Bool) {
        isEnabled = enabled && !tabs.isEmpty
        if !enabled { documentPanel.dismiss() }
    }

    @objc private func showDocuments() {
        showDocumentSwitcher()
    }

    func showDocumentSwitcher() {
        guard isEnabled, !tabs.isEmpty else { return }
        documentPanel.apply(tabs: tabs)
        documentPanel.present(relativeTo: self)
    }

    private func updateButtonLabel() {
        title = tabs.isEmpty ? "Documents" : "Documents (\(tabs.count))"
        toolTip = tabs.isEmpty ? "No Open Documents" : "Open Documents (\(tabs.count))"
        setAccessibilityValue(tabs.isEmpty ? "No open documents" : "\(tabs.count) open documents")
    }
}
