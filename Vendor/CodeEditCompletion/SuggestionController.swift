// Adapted from CodeEditSourceEditor/CodeSuggestion/{Window,TableView} (MIT).
// Copyright (c) 2022 CodeEdit. See LICENSE.md and PROVENANCE.md.
import AppKit

private final class SuggestionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor public final class SuggestionController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scroller = NSScrollView()
    private let documentation = NSTextView()
    private let documentationScroller = NSScrollView()
    private let documentationDivider = NSView()
    private var theme = CodeSuggestionTheme.system
    private var items: [CodeSuggestionItem] = []
    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    public var onAccept: ((Int, Bool) -> Bool)?
    public var onDismiss: (() -> Void)?
    public var onSelect: ((Int) -> Void)?
    public var canHandleKeys: (() -> Bool)?
    private var explicitSelection = false
    private var updatingItems = false
    private var cursorRect = NSRect.zero
    private var screenFrame = NSRect.zero
    public var isVisible: Bool { window?.isVisible == true }
    public var itemCount: Int { items.count }
    public var selectedIndex: Int { table.selectedRow }

    public init() {
        let panel = SuggestionWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true; panel.tabbingMode = .disallowed
        super.init(window: panel)
        let content = NSView()
        content.wantsLayer = true; content.layer?.cornerRadius = 4
        content.layer?.masksToBounds = true; content.layer?.borderWidth = 1
        panel.contentView = content
        scroller.documentView = table; scroller.hasVerticalScroller = true; scroller.drawsBackground = false
        scroller.autohidesScrollers = true; scroller.scrollerStyle = .overlay
        let column = NSTableColumn(identifier: .init("suggestion")); column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear; table.intercellSpacing = .zero
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(acceptDoubleClick)
        documentation.isEditable = false; documentation.isSelectable = true; documentation.isRichText = false
        documentation.drawsBackground = false; documentation.textColor = .secondaryLabelColor
        documentation.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        documentation.textContainerInset = NSSize(width: 12, height: 10)
        documentation.isVerticallyResizable = true; documentation.isHorizontallyResizable = false
        documentation.minSize = .zero
        documentation.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        documentation.autoresizingMask = []
        documentation.textContainer?.widthTracksTextView = false
        documentation.textContainer?.lineFragmentPadding = 0
        documentation.textContainer?.lineBreakMode = .byWordWrapping
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        documentation.defaultParagraphStyle = paragraph
        documentationScroller.documentView = documentation
        documentationScroller.hasVerticalScroller = true; documentationScroller.autohidesScrollers = true
        documentationScroller.scrollerStyle = .overlay; documentationScroller.drawsBackground = false
        documentationDivider.wantsLayer = true
        for view in [scroller, documentationScroller, documentationDivider] { content.addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show(items: [CodeSuggestionItem], at cursorRect: NSRect, parent: NSWindow, font: NSFont, footer: String, theme: CodeSuggestionTheme) {
        guard !items.isEmpty, let window, let content = window.contentView else { close(); return }
        onSelect = nil
        let selected = explicitSelection && self.items.indices.contains(table.selectedRow) ? self.items[table.selectedRow].label : nil
        if !isVisible { explicitSelection = false }
        self.items = items; self.font = font; self.theme = theme
        table.setAccessibilityHelp(footer)
        self.cursorRect = cursorRect
        let visibleScreen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        screenFrame = parent.convertToScreen(parent.contentLayoutRect).intersection(visibleScreen)
        guard !screenFrame.isEmpty else { close(); return }
        window.appearance = parent.effectiveAppearance
        parent.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.backgroundColor = theme.background.cgColor
            content.layer?.borderColor = theme.border.cgColor
        }
        documentation.textColor = theme.secondary
        documentation.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        documentationDivider.layer?.backgroundColor = theme.border.cgColor
        table.rowHeight = max(22, ceil(font.ascender - font.descender) + 6)
        updatingItems = true
        table.reloadData()
        table.enumerateAvailableRowViews { view, _ in
            (view as? CodeSuggestionRowView)?.selectionColor = theme.selection
            view.needsDisplay = true
        }
        table.selectRowIndexes(IndexSet(integer: items.firstIndex(where: { $0.label == selected }) ?? 0), byExtendingSelection: false)
        updatingItems = false
        let selectedIndex = items.indices.contains(table.selectedRow) ? table.selectedRow : 0
        setDocumentation(items[selectedIndex].documentation)
        layoutPanel()
        guard !self.items.isEmpty else { return }
        if window.parent !== parent { window.parent?.removeChildWindow(window); parent.addChildWindow(window, ordered: .above) }
        window.orderFront(nil)
        installMonitors(parent)
    }

    private func setDocumentation(_ text: String) {
        documentation.string = text
        documentationScroller.contentView.scroll(to: .zero)
        documentationScroller.reflectScrolledClipView(documentationScroller.contentView)
    }

    private func layoutPanel() {
        guard !items.isEmpty, let window else { return }
        let screen = screenFrame
        let hasDocumentation = !documentation.string.isEmpty
        let textWidth = items.prefix(100).map { ($0.label as NSString).size(withAttributes: [.font: font]).width
            + ($0.detail as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 64 }.max() ?? 280
        let width = min(max(hasDocumentation ? 320 : 280, textWidth), min(440, screen.width - 16))
        let below = max(0, cursorRect.minY - screen.minY - 8)
        let above = max(0, screen.maxY - cursorRect.maxY - 8)
        let maximumHeight = min(320, screen.height - 16, max(above, below))
        let padding: CGFloat = hasDocumentation ? 18 : 12
        guard maximumHeight >= table.rowHeight + padding else { close(); return }
        // Set the viewport before measuring its wrapping document.
        documentationScroller.frame = NSRect(x: 0, y: 6, width: width, height: documentationScroller.frame.height)
        let documentWidth = documentationScroller.contentSize.width
        documentation.frame.size.width = documentWidth
        documentation.textContainer?.containerSize = NSSize(width: max(1, documentWidth - 24), height: .greatestFiniteMagnitude)
        if let container = documentation.textContainer { documentation.layoutManager?.ensureLayout(for: container) }
        let textHeight = documentation.textContainer.map { documentation.layoutManager?.usedRect(for: $0).height ?? 0 } ?? 0
        let docHeight: CGFloat = hasDocumentation ? min(max(44, ceil(textHeight) + 20), 160,
            max(0, maximumHeight - table.rowHeight - padding)) : 0
        let rows = min(CGFloat(min(items.count, 8)), max(1, floor((maximumHeight - docHeight - padding) / table.rowHeight)))
        let listHeight = rows * table.rowHeight
        let height = listHeight + docHeight + padding
        scroller.frame = NSRect(x: 0, y: hasDocumentation ? docHeight + 12 : 6, width: width, height: listHeight)
        table.frame.size.width = width
        documentationScroller.frame.size.height = docHeight
        documentation.frame = NSRect(x: 0, y: 0, width: documentWidth, height: max(docHeight, ceil(textHeight) + 20))
        documentationScroller.isHidden = !hasDocumentation
        documentationDivider.isHidden = !hasDocumentation
        documentationDivider.frame = NSRect(x: 8, y: docHeight + 8, width: width - 16, height: 1)
        var origin = NSPoint(x: cursorRect.minX - 27, y: cursorRect.minY - height - 3)
        origin.x = min(max(screen.minX + 8, origin.x), screen.maxX - width - 8)
        if height > below { origin.y = cursorRect.maxY + 3 }
        origin.y = min(max(screen.minY + 8, origin.y), screen.maxY - height - 8)
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
    }

    private func installMonitors(_ parent: NSWindow) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self, weak parent] event in
            let handled = MainActor.assumeIsolated { self?.handle(event, parent: parent) ?? false }
            return handled ? nil : event
        }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
    private func handle(_ event: NSEvent, parent: NSWindow?) -> Bool {
        guard isVisible else { return false }
        if event.type != .keyDown {
            if event.window !== window { close() } else { explicitSelection = true }
            return false
        }
        guard event.window === parent else { return false }
        guard canHandleKeys?() != false else { close(); return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { close(); return false }
        switch event.keyCode {
        case 53: close(); return true
        case 125, 126:
            explicitSelection = true
            let index = min(max(0, table.selectedRow + (event.keyCode == 125 ? 1 : -1)), items.count - 1)
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index); return true
        case 36, 48:
            guard !event.modifierFlags.contains(.shift) else { close(); return false }
            let accepted = onAccept?(table.selectedRow, event.keyCode == 48) == true
            close(); return accepted
        default: return false
        }
    }
    public override func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        if let window { window.orderOut(nil); window.parent?.removeChildWindow(window) }
        items.removeAll(); table.reloadData(); onAccept = nil; onSelect = nil; onDismiss?()
    }
    public func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CodeSuggestionRowView(); view.selectionColor = theme.selection; return view
    }
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let view = tableView.makeView(withIdentifier: .init("completion-row"), owner: nil) as? CodeSuggestionLabelView ?? CodeSuggestionLabelView()
        view.identifier = .init("completion-row"); view.apply(items[row], font: font, theme: theme); return view
    }
    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingItems, items.indices.contains(table.selectedRow) else { return }
        setDocumentation(items[table.selectedRow].documentation)
        layoutPanel()
        onSelect?(table.selectedRow)
    }
    public func updateInfo(at index: Int, detail: String, documentation text: String) {
        guard isVisible, items.indices.contains(index) else { return }
        if !detail.isEmpty { items[index].detail = detail }
        items[index].documentation = text
        updatingItems = true
        table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        updatingItems = false
        guard table.selectedRow == index else { return }
        setDocumentation(text)
        layoutPanel()
    }
    @objc private func acceptDoubleClick() { _ = onAccept?(table.selectedRow, false); close() }
}
