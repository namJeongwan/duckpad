import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
struct DocumentSwitcherSearch {
    static func matchingIndices(in tabs: [TabSnapshot], query: String) -> [Int] {
        let terms = folded(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return Array(tabs.indices) }
        let phrase = terms.joined(separator: " ")

        return tabs.indices.compactMap { index -> (index: Int, tier: Int)? in
            let tab = tabs[index]
            let title = folded(tab.title)
            let path = folded(tab.fullPath ?? "")
            let searchable = title + "\n" + path
            guard terms.allSatisfy({ searchable.contains($0) }) else { return nil }

            let tier: Int
            if title == phrase { tier = 0 }
            else if title.hasPrefix(phrase) { tier = 1 }
            else if title.contains(phrase) { tier = 2 }
            else if terms.allSatisfy({ title.contains($0) }) { tier = 3 }
            else if terms.contains(where: { title.contains($0) }) { tier = 4 }
            else { tier = 5 }
            return (index, tier)
        }
        .sorted { lhs, rhs in
            lhs.tier == rhs.tier ? lhs.index < rhs.index : lhs.tier < rhs.tier
        }
        .map(\.index)
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

@MainActor
final class DocumentSwitcherPanel: NSObject,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate
{
    var onActivate: ((TabID) -> Void)?

    private(set) var tabs: [TabSnapshot] = []
    private(set) var filteredIndices: [Int] = []
    private let searchField = NSSearchField(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "No matching documents")
    private let countLabel = NSTextField(labelWithString: "")
    private var popover: NSPopover?
    private let contentController = NSViewController()
    private let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 340))
    private weak var hostWindow: NSWindow?

    var isPresented: Bool { popover?.isShown == true }
    var filteredTabs: [TabSnapshot] { filteredIndices.map { tabs[$0] } }
    var selectedTabID: TabID? {
        let row = tableView.selectedRow
        guard filteredIndices.indices.contains(row) else { return nil }
        return tabs[filteredIndices[row]].id
    }

    override init() {
        super.init()
        rootView.setAccessibilityIdentifier("duckpad.documents.panel")

        searchField.placeholderString = "Search open documents"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("duckpad.documents.search")
        searchField.setAccessibilityLabel("Search open documents")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)
        tableView.setAccessibilityIdentifier("duckpad.documents.results")
        tableView.setAccessibilityLabel("Open document search results")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.setAccessibilityIdentifier("duckpad.documents.empty")

        countLabel.textColor = .tertiaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(searchField)
        rootView.addSubview(scrollView)
        rootView.addSubview(emptyLabel)
        rootView.addSubview(countLabel)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -4),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 12),
            countLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -12),
            countLabel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -8),
            countLabel.heightAnchor.constraint(equalToConstant: 13),
        ])
        contentController.view = rootView
    }

    func apply(tabs: [TabSnapshot]) {
        self.tabs = tabs
        refilter(selectActive: true)
    }

    func present(relativeTo positioningView: NSView) {
        guard !tabs.isEmpty, let window = positioningView.window else { return }
        stopObservingHostWindow()
        hostWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        searchField.stringValue = ""
        refilter(selectActive: true)
        let height = min(CGFloat(340), max(CGFloat(150), CGFloat(74 + min(tabs.count, 6) * 46)))
        rootView.frame.size = NSSize(width: 420, height: height)
        if popover?.isShown != true {
            let nextPopover = NSPopover()
            nextPopover.behavior = .transient
            nextPopover.animates = true
            nextPopover.delegate = self
            nextPopover.contentSize = rootView.frame.size
            nextPopover.contentViewController = contentController
            popover = nextPopover
            nextPopover.show(relativeTo: positioningView.bounds, of: positioningView, preferredEdge: .minY)
        }
        contentController.view.window?.makeFirstResponder(searchField)
    }

    func dismiss() {
        stopObservingHostWindow()
        let closingPopover = popover
        popover = nil
        closingPopover?.close()
    }

    func selectResult(at index: Int) {
        guard filteredIndices.indices.contains(index) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    func activateSelectedResult() {
        activateSelection()
    }

    func setQuery(_ query: String) {
        searchField.stringValue = query
        refilter(selectActive: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredIndices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredIndices.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("DocumentSwitcherCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        let tab = tabs[filteredIndices[row]]
        let title = tab.title + (tab.isDirty ? "  •" : "")
        cell.textField?.stringValue = title
        cell.textField?.textColor = tab.isDirty ? .labelColor : .secondaryLabelColor
        cell.imageView?.image = NSImage(
            systemSymbolName: tab.isPinned ? "pin.fill" : (tab.fullPath == nil ? "note.text" : "doc.text"),
            accessibilityDescription: nil
        )
        cell.toolTip = tab.fullPath ?? "Unsaved scratch document"
        cell.setAccessibilityLabel(
            tab.title
                + (tab.isActive ? ", current document" : "")
                + (tab.isDirty ? ", modified" : "")
                + (tab.isPinned ? ", pinned" : "")
                + (tab.fullPath.map { ", \($0)" } ?? ", unsaved scratch document")
        )
        if let detail = cell.viewWithTag(41) as? NSTextField {
            detail.stringValue = tab.fullPath ?? "Unsaved scratch document"
        }
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        refilter(selectActive: false)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        if let closedPopover = notification.object as? NSPopover, popover === closedPopover {
            popover = nil
        }
        stopObservingHostWindow()
        searchField.stringValue = ""
    }

    @objc private func hostWindowWillClose(_ notification: Notification) {
        dismiss()
    }

    @objc private func activateSelection() {
        let row = tableView.selectedRow
        guard filteredIndices.indices.contains(row) else { return }
        let id = tabs[filteredIndices[row]].id
        dismiss()
        onActivate?(id)
    }

    private func refilter(selectActive: Bool) {
        filteredIndices = DocumentSwitcherSearch.matchingIndices(in: tabs, query: searchField.stringValue)
        tableView.reloadData()
        emptyLabel.isHidden = !filteredIndices.isEmpty
        countLabel.stringValue = filteredIndices.count == tabs.count
            ? "\(tabs.count) open"
            : "\(filteredIndices.count) of \(tabs.count)"
        guard !filteredIndices.isEmpty else { return }
        let activeTabIndex = tabs.firstIndex(where: \.isActive)
        let activeResult = activeTabIndex.flatMap { filteredIndices.firstIndex(of: $0) }
        selectResult(at: selectActive ? (activeResult ?? 0) : 0)
    }

    private func moveSelection(by delta: Int) {
        guard !filteredIndices.isEmpty else { return }
        let current = max(tableView.selectedRow, 0)
        selectResult(at: min(max(current + delta, 0), filteredIndices.count - 1))
    }

    private func stopObservingHostWindow() {
        if let hostWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: hostWindow
            )
        }
        hostWindow = nil
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(frame: .zero)
        cell.identifier = identifier
        let icon = NSImageView(frame: .zero)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(labelWithString: "")
        detail.tag = 41
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(title)
        cell.addSubview(detail)
        cell.imageView = icon
        cell.textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
        return cell
    }
}
