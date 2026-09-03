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
    private let documentsMenu = NSMenu(title: "Open Documents")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(showDocuments)
        bezelStyle = .inline
        isBordered = false
        image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Open Documents")
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        contentTintColor = .secondaryLabelColor
        toolTip = "Open Documents"
        setAccessibilityIdentifier("duckpad.tab.documents")
        setAccessibilityLabel("Open Documents")
        translatesAutoresizingMaskIntoConstraints = false
        updateButtonLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(tabs: [TabSnapshot]) {
        self.tabs = tabs
        rebuildMenu()
        updateMetrics.fullRebuilds += 1
    }

    func apply(change: WorkspaceChange) {
        switch change.kind {
        case .persistence:
            guard tabs.count == change.snapshot.tabs.count else {
                apply(tabs: change.snapshot.tabs)
                return
            }
            tabs = change.snapshot.tabs
        case .tabUpdated(let index), .bufferEdited(let index):
            guard tabs.count == change.snapshot.tabs.count,
                  tabs.indices.contains(index), documentsMenu.items.indices.contains(index) else {
                apply(tabs: change.snapshot.tabs)
                return
            }
            tabs[index] = change.snapshot.tabs[index]
            configure(documentsMenu.items[index], tab: tabs[index], index: index)
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
                  affected.allSatisfy({ tabs.indices.contains($0) && documentsMenu.items.indices.contains($0) }) else {
                apply(tabs: change.snapshot.tabs)
                return
            }
            tabs = change.snapshot.tabs
            for index in affected {
                configure(documentsMenu.items[index], tab: tabs[index], index: index)
            }
            updateMetrics.itemUpdates += affected.count
            updateMetrics.incrementalItemInspections += affected.count
        default:
            apply(tabs: change.snapshot.tabs)
        }
        updateButtonLabel()
    }

    func setInteractionsEnabled(_ enabled: Bool) {
        isEnabled = enabled && !tabs.isEmpty
    }

    func menuItem(for tabID: TabID) -> NSMenuItem? {
        documentsMenu.items.first { ($0.representedObject as? String) == tabID.rawValue.uuidString }
    }

    var menuItems: [NSMenuItem] { documentsMenu.items }

    @objc private func showDocuments() {
        guard isEnabled, !documentsMenu.items.isEmpty else { return }
        let active = tabs.firstIndex(where: \.isActive).flatMap {
            documentsMenu.items.indices.contains($0) ? documentsMenu.items[$0] : nil
        }
        documentsMenu.popUp(
            positioning: active,
            at: NSPoint(x: bounds.minX, y: bounds.minY - 4),
            in: self
        )
    }

    @objc private func activateDocument(_ sender: NSMenuItem) {
        guard isEnabled,
              let raw = sender.representedObject as? String,
              let uuid = UUID(uuidString: raw) else { return }
        onActivate?(TabID(rawValue: uuid))
    }

    private func rebuildMenu() {
        documentsMenu.removeAllItems()
        for (index, tab) in tabs.enumerated() {
            let item = NSMenuItem(title: "", action: #selector(activateDocument(_:)), keyEquivalent: "")
            item.target = self
            documentsMenu.addItem(item)
            configure(item, tab: tab, index: index)
        }
        updateButtonLabel()
        setInteractionsEnabled(isEnabled)
    }

    private func configure(_ item: NSMenuItem, tab: TabSnapshot, index: Int) {
        let dirtySuffix = tab.isDirty ? " — Edited" : ""
        item.title = "\(index + 1). \(tab.title)\(dirtySuffix)"
        item.representedObject = tab.id.rawValue.uuidString
        item.state = tab.isActive ? .on : .off
        item.image = NSImage(
            systemSymbolName: tab.isPinned ? "pin.fill" : (tab.fullPath == nil ? "note.text" : "doc.text"),
            accessibilityDescription: nil
        )
        item.toolTip = tab.fullPath ?? "Unsaved scratch document"
        item.setAccessibilityLabel(
            "Document \(index + 1), \(tab.title), "
                + (tab.isActive ? "selected" : "not selected")
                + (tab.isDirty ? ", modified" : "")
                + (tab.isPinned ? ", pinned" : "")
        )
    }

    private func updateButtonLabel() {
        title = tabs.isEmpty ? "" : "\(tabs.count)"
        toolTip = tabs.isEmpty ? "No Open Documents" : "Open Documents (\(tabs.count))"
        setAccessibilityValue(tabs.isEmpty ? "No open documents" : "\(tabs.count) open documents")
    }
}
