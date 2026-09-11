import DuckpadLocalization
import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
struct DocumentSwitcherSearch {
    static func matchingIndices(in tabs: [TabSnapshot], query: String) -> [Int] {
        matchingEntries(in: tabs, query: query).map(\.index)
    }

    static func matchingEntries(
        in tabs: [TabSnapshot],
        query: String
    ) -> [(index: Int, tier: Int)] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return tabs.indices.map { ($0, 0) } }

        return tabs.indices.compactMap { index in
            matchTier(for: tabs[index], terms: terms).map { (index, $0) }
        }
        .sorted { lhs, rhs in
            lhs.tier == rhs.tier ? lhs.index < rhs.index : lhs.tier < rhs.tier
        }
    }

    static func terms(in query: String) -> [String] {
        folded(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matchTier(for tab: TabSnapshot, terms: [String]) -> Int? {
        guard !terms.isEmpty else { return 0 }
        let phrase = terms.joined(separator: " ")
        let title = folded(tab.title)
        let path = folded(tab.fullPath ?? "")
        let searchable = title + "\n" + path
        guard terms.allSatisfy({ searchable.contains($0) }) else { return nil }
        if title == phrase { return 0 }
        if title.hasPrefix(phrase) { return 1 }
        if title.contains(phrase) { return 2 }
        if terms.allSatisfy({ title.contains($0) }) { return 3 }
        if terms.contains(where: { title.contains($0) }) { return 4 }
        return 5
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
    struct UpdateMetrics: Equatable {
        fileprivate(set) var fullScans = 0
        fileprivate(set) var fullReloads = 0
        fileprivate(set) var directItemInspections = 0
        fileprivate(set) var rowInsertions = 0
        fileprivate(set) var rowRemovals = 0
        fileprivate(set) var rowUpdates = 0
        fileprivate(set) var filteredReorders = 0
        fileprivate(set) var rankSearches = 0
    }

    var onActivate: ((TabID) -> Void)?

    private(set) var tabs: [TabSnapshot] = []
    private(set) var filteredIndices: [Int] = []
    private var filteredTiers: [Int: Int] = [:]
    private var filteredRows: [Int: Int] = [:]
    private var filteredRowsAreValid = false
    private(set) var updateMetrics = UpdateMetrics()
    private let searchField = NSSearchField(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: L10n.text("No matching documents"))
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

    private var catalog = L10n.catalog

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        catalog.text(key, arguments: arguments)
    }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        searchField.placeholderString = localized("Search open documents")
        searchField.setAccessibilityLabel(localized("Search open documents"))
        tableView.setAccessibilityLabel(localized("Open document search results"))
        emptyLabel.stringValue = localized("No matching documents")
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()
        tableView.selectRowIndexes(selection, byExtendingSelection: false)
        updateResultChrome()
    }

    override init() {
        super.init()
        rootView.setAccessibilityIdentifier("duckpad.documents.panel")

        searchField.placeholderString = localized("Search open documents")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("duckpad.documents.search")
        searchField.setAccessibilityLabel(localized("Search open documents"))
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
        tableView.setAccessibilityLabel(localized("Open document search results"))

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

    @discardableResult
    func apply(tab: TabSnapshot, at index: Int) -> Bool {
        guard tabs.indices.contains(index), tabs[index].id == tab.id else { return false }
        let selectedTabIndex = filteredIndices.indices.contains(tableView.selectedRow)
            ? filteredIndices[tableView.selectedRow]
            : nil
        let terms = DocumentSwitcherSearch.terms(in: searchField.stringValue)
        let oldTier = filteredTiers[index]
        let newTier = DocumentSwitcherSearch.matchTier(for: tab, terms: terms)

        if filteredRowsAreValid,
           let oldRow = filteredRows[index],
           oldTier == newTier {
            updateMetrics.directItemInspections += 1
            tabs[index] = tab
            reloadRow(oldRow)
            updateMetrics.rowUpdates += 1
            return true
        }

        let oldRow = oldTier.flatMap { row(for: index, tier: $0) }
        guard oldTier == nil || oldRow != nil else { return false }
        updateMetrics.directItemInspections += 1
        tabs[index] = tab

        switch (oldRow, newTier) {
        case (nil, nil):
            break
        case (let oldRow?, nil):
            filteredRowsAreValid = false
            filteredIndices.remove(at: oldRow)
            filteredTiers.removeValue(forKey: index)
            rebuildFilteredRows()
            tableView.removeRows(at: IndexSet(integer: oldRow), withAnimation: [])
            updateMetrics.rowRemovals += 1
        case (nil, let newTier?):
            filteredRowsAreValid = false
            filteredTiers[index] = newTier
            let newRow = insertionRow(for: index, tier: newTier)
            filteredIndices.insert(index, at: newRow)
            rebuildFilteredRows()
            tableView.insertRows(at: IndexSet(integer: newRow), withAnimation: [])
            updateMetrics.rowInsertions += 1
        case (let oldRow?, let newTier?):
            filteredRowsAreValid = false
            filteredIndices.remove(at: oldRow)
            filteredTiers[index] = newTier
            let newRow = insertionRow(for: index, tier: newTier)
            filteredIndices.insert(index, at: newRow)
            updateMetrics.filteredReorders += 1
            rebuildFilteredRows()
            if oldRow != newRow { tableView.moveRow(at: oldRow, to: newRow) }
            reloadRow(newRow)
            updateMetrics.rowUpdates += 1
        }

        updateResultChrome()
        restoreSelection(previousTabIndex: selectedTabIndex, changedTabIndex: index)
        return true
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
        cell.toolTip = tab.fullPath ?? localized("Unsaved scratch document")
        cell.setAccessibilityLabel(
            tab.title
                + (tab.isActive ? localized(", current document") : "")
                + (tab.isDirty ? localized(", modified") : "")
                + (tab.isPinned ? localized(", pinned") : "")
                + (tab.fullPath.map { ", \($0)" } ?? localized(", unsaved scratch document"))
        )
        if let detail = cell.viewWithTag(41) as? NSTextField {
            detail.stringValue = tab.fullPath ?? localized("Unsaved scratch document")
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
        let entries = DocumentSwitcherSearch.matchingEntries(in: tabs, query: searchField.stringValue)
        filteredIndices = entries.map(\.index)
        filteredTiers = Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0.tier) })
        rebuildFilteredRows()
        updateMetrics.fullScans += tabs.count
        tableView.reloadData()
        updateMetrics.fullReloads += 1
        updateResultChrome()
        guard !filteredIndices.isEmpty else { return }
        let activeTabIndex = tabs.firstIndex(where: \.isActive)
        let activeResult = activeTabIndex.flatMap { filteredIndices.firstIndex(of: $0) }
        selectResult(at: selectActive ? (activeResult ?? 0) : 0)
    }

    private func row(for tabIndex: Int, tier: Int) -> Int? {
        updateMetrics.rankSearches += 1
        let candidate = insertionRow(for: tabIndex, tier: tier)
        guard filteredIndices.indices.contains(candidate),
              filteredIndices[candidate] == tabIndex else { return nil }
        return candidate
    }

    private func rebuildFilteredRows() {
        filteredRows = Dictionary(
            uniqueKeysWithValues: filteredIndices.enumerated().map { ($0.element, $0.offset) }
        )
        filteredRowsAreValid = true
    }

    private func insertionRow(for tabIndex: Int, tier: Int) -> Int {
        var lower = 0
        var upper = filteredIndices.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let existingIndex = filteredIndices[middle]
            let existingTier = filteredTiers[existingIndex] ?? Int.max
            if existingTier < tier || (existingTier == tier && existingIndex < tabIndex) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private func restoreSelection(previousTabIndex: Int?, changedTabIndex: Int) {
        if tabs[changedTabIndex].isActive,
           let tier = filteredTiers[changedTabIndex],
           let activeRow = row(for: changedTabIndex, tier: tier) {
            selectResult(at: activeRow)
            return
        }
        if let previousTabIndex,
           let tier = filteredTiers[previousTabIndex],
           let previousRow = row(for: previousTabIndex, tier: tier) {
            selectResult(at: previousRow)
            return
        }
        if !filteredIndices.isEmpty {
            selectResult(at: min(max(tableView.selectedRow, 0), filteredIndices.count - 1))
        }
    }

    private func reloadRow(_ row: Int) {
        guard tableView.tableColumns.indices.contains(0) else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    private func updateResultChrome() {
        emptyLabel.isHidden = !filteredIndices.isEmpty
        countLabel.stringValue = filteredIndices.count == tabs.count
            ? localized("%1$@ open", L10n.argument(tabs.count))
            : localized("%1$@ of %2$@", L10n.argument(filteredIndices.count), L10n.argument(tabs.count))
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
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
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
            icon.widthAnchor.constraint(equalToConstant: 23),
            icon.heightAnchor.constraint(equalToConstant: 23),
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
