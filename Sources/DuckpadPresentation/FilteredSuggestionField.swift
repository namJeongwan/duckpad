import AppKit
import DuckpadLocalization

/// An editable value with a live, filtered list. Updating the list never edits
/// the field editor, so marked text and the user's caret remain owned by AppKit.
@MainActor final class FilteredSuggestionField: NSControl, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let input = SearchInputField(fontSize: 13)
    private let disclosure = StatusBarButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!, target: nil, action: nil)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private let surface = SearchSurfaceView(.editor)
    private var hoverTrackingArea: NSTrackingArea?
    private var hovered = false
    private var editing = false
    private var candidates = [String]()
    private var fieldEnabled = true
    private var selectedSuggestion: String?
    private var filtering = false
    private(set) var filteredSuggestions = [String]()
    private(set) var suggestionPanel: NSPanel?
    private var eventMonitor: Any?
    private var inactiveObserver: NSObjectProtocol?
    private let symbolName: String
    var onChange: (() -> Void)?

    init(symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        input.delegate = self
        // The composite control owns its entire outline, including the arrow.
        input.showsInteractionChrome = false
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.translatesAutoresizingMaskIntoConstraints = false
        disclosure.target = self; disclosure.action = #selector(toggleSuggestions)
        disclosure.configureAsToolbarIcon(pointSize: 11)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.layer?.cornerRadius = 5
        addSubview(surface); addSubview(input); addSubview(disclosure)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor), surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor), surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), input.trailingAnchor.constraint(equalTo: disclosure.leadingAnchor, constant: -4),
            input.topAnchor.constraint(equalTo: topAnchor), input.bottomAnchor.constraint(equalTo: bottomAnchor),
            disclosure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3), disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 22), disclosure.heightAnchor.constraint(equalToConstant: 24),
        ])
        setAccessibilityElement(false)
        let column = NSTableColumn(identifier: .init("suggestion")); table.addTableColumn(column)
        table.headerView = nil; table.style = .plain; table.rowHeight = 32; table.intercellSpacing = .zero
        table.allowsEmptySelection = true; table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(chooseClickedSuggestion)
        table.backgroundColor = .clear; table.focusRingType = .none
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor
        refreshLocalization()
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { .init(width: 180, height: SearchInputField.preferredHeight) }
    override var stringValue: String {
        get { input.stringValue }
        set { input.stringValue = newValue; selectedSuggestion = nil; filtering = false; updateSuggestions(show: false) }
    }
    var placeholderString: String? {
        get { input.placeholderString }
        set { input.placeholderString = newValue }
    }
    override var font: NSFont? {
        get { input.font }
        set { input.font = newValue }
    }
    override var isEnabled: Bool {
        get { fieldEnabled }
        set {
            guard fieldEnabled != newValue else { return }
            fieldEnabled = newValue; input.isEnabled = newValue; disclosure.isEnabled = newValue
            if !newValue { editing = false; dismissSuggestions() }
            synchronizeHover()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); hoverTrackingArea = area
        synchronizeHover()
    }
    override func mouseEntered(with event: NSEvent) { hovered = isEnabled; refreshChrome() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshChrome() }
    private func synchronizeHover() {
        if isEnabled, let window, !isHiddenOrHasHiddenAncestor {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hovered = bounds.contains(point) && visibleRect.contains(point)
        } else { hovered = false }
        refreshChrome()
    }
    private func refreshChrome() {
        surface.isInteractionHovered = isEnabled && hovered
        surface.isInteractionFocused = isEnabled && editing
    }
    func focus() { window?.makeFirstResponder(input) }
    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        let label = catalog.text("Show suggestions")
        disclosure.toolTip = label; disclosure.setAccessibilityLabel(label)
        empty.stringValue = catalog.text("No matches")
        table.setAccessibilityLabel(catalog.text("Suggestions for %1$@", arguments: [input.accessibilityLabel() ?? ""]))
    }
    func setSuggestions(_ values: [String]) {
        var seen = Set<String>()
        candidates = values.filter { seen.insert($0).inserted }
        updateSuggestions(show: input.currentEditor() != nil)
    }
    private func updateSuggestions(show: Bool) {
        // Read the editor during composition; the control's committed value can
        // lag the marked text. Do not reload/deselect the editable control.
        let query = filtering ? ((input.currentEditor() as? NSTextView)?.string ?? input.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines) : ""
        filteredSuggestions = query.isEmpty ? candidates : candidates.filter { $0.localizedStandardContains(query) }
        table.reloadData()
        if let selectedSuggestion, let row = filteredSuggestions.firstIndex(of: selectedSuggestion) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            selectedSuggestion = nil; table.deselectAll(nil)
        }
        empty.isHidden = !filteredSuggestions.isEmpty; scroll.isHidden = filteredSuggestions.isEmpty
        if show, !candidates.isEmpty { showSuggestions() }
        else if suggestionPanel?.isVisible == true { positionSuggestions() }
    }
    func controlTextDidBeginEditing(_ obj: Notification) { editing = true; refreshChrome(); selectedSuggestion = nil; filtering = false; updateSuggestions(show: true) }
    func controlTextDidChange(_ obj: Notification) { selectedSuggestion = nil; filtering = true; updateSuggestions(show: true); onChange?() }
    func controlTextDidEndEditing(_ obj: Notification) { editing = false; refreshChrome(); dismissSuggestions() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            if suggestionPanel?.isVisible != true { updateSuggestions(show: true) }
            guard !filteredSuggestions.isEmpty else { return true }
            let delta = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = table.selectedRow < 0 ? (delta > 0 ? 0 : filteredSuggestions.count - 1)
                : max(0, min(filteredSuggestions.count - 1, table.selectedRow + delta))
            selectedSuggestion = filteredSuggestions[row]
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if suggestionPanel?.isVisible == true, let selectedSuggestion, let row = filteredSuggestions.firstIndex(of: selectedSuggestion) { choose(row: row) }
            else { dismissSuggestions() }
            if let action { sendAction(action, to: target) }
            return true
        case #selector(NSResponder.cancelOperation(_:)) where suggestionPanel?.isVisible == true:
            dismissSuggestions(); return true
        default: return false
        }
    }
    @objc private func toggleSuggestions() {
        if suggestionPanel?.isVisible == true { dismissSuggestions() }
        else { focus(); selectedSuggestion = nil; filtering = false; updateSuggestions(show: true) }
    }
    @objc private func chooseClickedSuggestion() { choose(row: table.clickedRow >= 0 ? table.clickedRow : table.selectedRow) }
    func choose(row: Int) {
        guard filteredSuggestions.indices.contains(row) else { return }
        let value = filteredSuggestions[row]
        // Clicking a suggestion explicitly accepts it, including during IME
        // composition. Return while marked is still left to the input method.
        (input.currentEditor() as? NSTextView)?.unmarkText()
        selectedSuggestion = nil; filtering = false
        input.stringValue = value
        if let editor = input.currentEditor() as? NSTextView {
            editor.string = value; editor.setSelectedRange(.init(location: value.utf16.count, length: 0))
        }
        dismissSuggestions(); onChange?()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filteredSuggestions.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CommandPaletteRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredSuggestions.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("suggestion")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.identifier == nil {
            cell.identifier = id
            let icon = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)!)
            icon.contentTintColor = .secondaryLabelColor
            let label = NSTextField(labelWithString: ""); label.font = input.font; label.lineBreakMode = .byTruncatingMiddle
            let row = NSStackView(views: [icon, label]); row.spacing = 7; row.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(row); cell.textField = label; cell.imageView = icon
            NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
        }
        cell.textField?.stringValue = filteredSuggestions[row]
        return cell
    }
    private func showSuggestions() {
        guard let window, window.isVisible, isEnabled, !isHiddenOrHasHiddenAncestor else { return }
        if suggestionPanel == nil {
            let panel = SuggestionListPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.hasShadow = true; panel.backgroundColor = .clear; panel.isOpaque = false
            panel.level = .popUpMenu; panel.hidesOnDeactivate = true
            let root = SearchSurfaceView(.panel); root.layer?.cornerRadius = 7; root.layer?.masksToBounds = true
            root.addSubview(scroll); root.addSubview(empty)
            panel.contentView = root; suggestionPanel = panel
        }
        guard let panel = suggestionPanel else { return }
        panel.appearance = window.effectiveAppearance
        if panel.parent !== window { panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above) }
        positionSuggestions(); panel.orderFront(nil)
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consumed ? nil : event
            }
            inactiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissSuggestions() }
            }
        }
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            if event.keyCode == 53, event.window === window, input.currentEditor() != nil,
               (input.currentEditor() as? NSTextView)?.hasMarkedText() != true {
                dismissSuggestions(); return nil
            }
        } else if event.window !== suggestionPanel {
            let point = convert(event.locationInWindow, from: nil)
            if event.window !== window || !bounds.contains(point) { dismissSuggestions() }
        }
        return event
    }
    private func positionSuggestions() {
        guard let panel = suggestionPanel, let window else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? anchor.insetBy(dx: -1_000, dy: -1_000)
        let padding: CGFloat = 6
        let desiredHeight = CGFloat(min(12, max(1, filteredSuggestions.count))) * table.rowHeight + padding * 2
        let below = max(0, anchor.minY - visible.minY - 4)
        let above = max(0, visible.maxY - anchor.maxY - 4)
        let opensBelow = below >= desiredHeight || below >= above
        let height = min(desiredHeight, max(36, opensBelow ? below : above))
        let width = min(visible.width, max(260, bounds.width))
        let x = max(visible.minX, min(anchor.minX, visible.maxX - width))
        let proposedY = opensBelow ? anchor.minY - height - 4 : anchor.maxY + 4
        let y = max(visible.minY, min(proposedY, visible.maxY - height))
        panel.setFrame(.init(x: x, y: y, width: width, height: height), display: false)
        scroll.frame = .init(x: padding, y: padding, width: width - padding * 2, height: height - padding * 2)
        empty.frame = .init(x: 12, y: 7, width: width - 24, height: 20)
    }
    override func layout() { super.layout(); if suggestionPanel?.isVisible == true { positionSuggestions() } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { editing = false; dismissSuggestions() }
        synchronizeHover()
    }
    func dismissSuggestions() {
        if let panel = suggestionPanel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver); self.inactiveObserver = nil }
    }
}

@MainActor private final class SuggestionListPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
