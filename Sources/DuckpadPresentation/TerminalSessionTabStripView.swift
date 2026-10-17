import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

@MainActor
final class TerminalSessionTabStripView: NSView {
    private let scroll = NSScrollView()
    private let document = FlippedTabDocumentView()
    private(set) var tabs: [TerminalSessionTabView] = []
    private var selectedID: UUID?
    private var preferences = AppSettings.defaults
    private var revealSelection = false
    var maximumHeight: CGFloat = 81 {
        didSet { if oldValue != maximumHeight { needsLayout = true } }
    }
    var onHeightChange: ((CGFloat) -> Void)?
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var contextMenu: ((UUID?) -> NSMenu?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("duckpad.terminal.sessions")
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { nil }

    func apply(sessions: [TerminalSessionStore.Session], selectedID: UUID?,
               preferences: AppSettings, catalog: LocalizationCatalog) {
        setAccessibilityLabel(catalog.text("Terminal sessions"))
        revealSelection = revealSelection || self.selectedID != selectedID
            || self.preferences.multilineTabsEnabled != preferences.multilineTabsEnabled
        self.selectedID = selectedID
        self.preferences = preferences
        let oldTabs = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        for tab in tabs where !sessions.contains(where: { $0.id == tab.id }) { tab.removeFromSuperview() }
        tabs = sessions.map { session in
            let tab = oldTabs[session.id] ?? TerminalSessionTabView(id: session.id)
            let title = catalog.text("Session %1$@", arguments: [session.number.formatted(.number.locale(catalog.locale))])
            tab.configure(title: title, directory: session.configuration.workingDirectory.path,
                          selected: session.id == selectedID, showClose: preferences.showTabCloseButton,
                          showInactiveClose: preferences.showInactiveTabButtons, catalog: catalog)
            tab.onSelect = { [weak self] in self?.onSelect?(session.id) }
            tab.onClose = { [weak self] in self?.onClose?(session.id) }
            tab.contextMenu = { [weak self] in self?.contextMenu?(session.id) }
            if tab.superview == nil { document.addSubview(tab) }
            return tab
        }
        needsLayout = true
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?(selectedID) }

    func focusSelectedTab() -> Bool {
        guard let tab = tabs.first(where: { $0.id == selectedID }) else { return false }
        return window?.makeFirstResponder(tab.activateButton) ?? false
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let result = TabFlowLayoutEngine(backingScale: window?.backingScaleFactor ?? 2,
                                         multilineEnabled: preferences.multilineTabsEnabled)
            .layout(itemWidths: tabs.map(\.preferredWidth), containerWidth: bounds.width)
        document.frame.size = NSSize(width: result.contentWidth, height: max(27, result.contentHeight))
        for (tab, frame) in zip(tabs, result.frames) { tab.frame = frame }
        scroll.hasHorizontalScroller = result.contentWidth > bounds.width + 1
        scroll.hasVerticalScroller = result.contentHeight > maximumHeight
        onHeightChange?(max(27, min(maximumHeight, result.contentHeight)))
        if revealSelection, let tab = tabs.first(where: { $0.id == selectedID }) {
            document.scrollToVisible(tab.frame)
            revealSelection = false
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { revealSelection = true }
        super.setFrameSize(newSize)
        needsLayout = true
    }
}

private final class FlippedTabDocumentView: NSView {
    override var isFlipped: Bool { true }
}
