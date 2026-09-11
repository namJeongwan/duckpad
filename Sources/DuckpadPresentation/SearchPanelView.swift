import DuckpadLocalization
import AppKit
import DuckpadDomain

@MainActor
private final class SearchResultsTable: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
final class SearchPanelView: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Tab: Int { case find, replace, folder, bookmarks }
    private enum ResultTarget { case openDocument(SearchMatch) }

    var onFind: ((SearchQuery) -> Void)?
    var onReplace: ((SearchQuery) -> Void)?
    var onReplaceAll: ((SearchQuery) -> Void)?
    var onFindAll: ((SearchQuery) -> Void)?
    var onFindInFolder: ((SearchQuery) -> Void)?
    var onMarkAll: ((SearchQuery, Bool) -> Void)?
    var onClearBookmarks: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onIncrementalQuery: ((SearchQuery) -> Void)?
    var onQueryInvalidated: (() -> Void)?
    var onActivateMatch: ((SearchMatch) -> Void)?
    var onActivateFolderMatch: ((FolderSearchDocumentResult, FolderSearchMatch) -> Void)?
    var onClose: (() -> Void)?
    var onCancel: (() -> Void)?
    var onLayoutChanged: (() -> Void)?
    private(set) var selectedTab: Tab = .find
    private(set) var folderURL: URL?

    let appearanceOptions = SearchWindowAppearanceView(frame: .zero)
    private let tabs = NSSegmentedControl(labels: ["", "", "", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let directoryField = NSTextField(labelWithString: "")
    private let replacementRow = NSStackView()
    private let directoryRow = NSStackView()
    private let modeButtons = (0..<3).map { _ in NSButton(radioButtonWithTitle: "", target: nil, action: nil) }
    private let matchCase = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let wholeWord = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dotMatchesNewline = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let wrap = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let inSelection = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let clearPrevious = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let modeBox = NSBox()
    private let backwards = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let folderHint = NSTextField(wrappingLabelWithString: "")
    private lazy var cancelButton = button("Cancel", #selector(cancelPressed))
    private let status = NSTextField(labelWithString: "")
    private let table = SearchResultsTable()
    private let resultsScroll = NSScrollView()
    private var actionButtons: [(NSButton, Set<Tab>)] = []
    private var localizedButtons: [(NSButton, String)] = []
    private var localizedLabels: [(NSTextField, String)] = []
    private var rows: [(String, ResultTarget?)] = []
    private var openResult: SearchResultSet?
    private var statusRenderer: ((LocalizationCatalog) -> String)?
    private var folderResult: FolderSearchResultSet?
    private var folderRowOffsets: [Int] = []
    private var incrementalTask: Task<Void, Never>?
    private var catalog = L10n.catalog

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        catalog.text(key, arguments: arguments)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("duckpad.search.panel")
        tabs.selectedSegment = 0
        tabs.segmentStyle = .rounded
        tabs.controlSize = .small
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.setAccessibilityIdentifier("duckpad.search.tabs")
        findField.delegate = self
        findField.setAccessibilityIdentifier("duckpad.search.find")
        replaceField.delegate = self
        replaceField.setAccessibilityIdentifier("duckpad.search.replace")
        directoryField.setAccessibilityIdentifier("duckpad.search.directory")
        directoryField.isSelectable = true
        directoryField.lineBreakMode = .byTruncatingMiddle
        for field in [findField as NSTextField, replaceField, directoryField] {
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let findRow = fieldRow("Find", field: findField)
        configureFieldRow(replacementRow, key: "Replace with", field: replaceField)
        let browse = button("Browse…", #selector(chooseFolderPressed))
        configureFieldRow(directoryRow, key: "Directory", field: horizontal([directoryField, browse]))
        folderHint.font = .systemFont(ofSize: 11)
        folderHint.textColor = .secondaryLabelColor
        folderHint.setAccessibilityIdentifier("duckpad.search.folder-hint")
        let fields = vertical([findRow, replacementRow, directoryRow, folderHint], spacing: 4)
        let inputArea = NSView()
        fields.translatesAutoresizingMaskIntoConstraints = false
        inSelection.translatesAutoresizingMaskIntoConstraints = false
        inputArea.addSubview(fields)
        inputArea.addSubview(inSelection)
        NSLayoutConstraint.activate([
            inputArea.heightAnchor.constraint(equalToConstant: 82),
            fields.topAnchor.constraint(equalTo: inputArea.topAnchor),
            fields.leadingAnchor.constraint(equalTo: inputArea.leadingAnchor),
            fields.trailingAnchor.constraint(equalTo: inputArea.trailingAnchor),
            inSelection.trailingAnchor.constraint(equalTo: inputArea.trailingAnchor),
            inSelection.bottomAnchor.constraint(equalTo: inputArea.bottomAnchor),
        ])

        for (index, control) in [matchCase, wholeWord, wrap, inSelection, dotMatchesNewline, backwards].enumerated() {
            control.target = self
            control.action = #selector(optionsChanged)
            control.setAccessibilityIdentifier("duckpad.search." + ["match-case", "whole-word", "wrap", "selection", "dot-newline", "backwards"][index])
        }
        for control in [matchCase, wholeWord, wrap, inSelection, dotMatchesNewline, backwards, clearPrevious] + modeButtons {
            control.controlSize = .small
            control.font = .systemFont(ofSize: 12)
        }
        wrap.state = .on
        for (index, control) in modeButtons.enumerated() {
            control.tag = index
            control.target = self
            control.action = #selector(modeChanged(_:))
            control.setAccessibilityIdentifier("duckpad.search.mode.\(index)")
        }
        modeButtons[0].state = .on
        dotMatchesNewline.isEnabled = false
        let options = vertical([clearPrevious, backwards, wholeWord, matchCase, wrap], spacing: 2)
        let regexRow = horizontal([modeButtons[2], dotMatchesNewline], spacing: 12)
        regexRow.distribution = .gravityAreas
        configureBox(modeBox, content: vertical([modeButtons[0], modeButtons[1], regexRow], spacing: 2))
        let left = vertical([inputArea, options, modeBox], spacing: 8)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true

        let actions = vertical([], spacing: 4)
        func addAction(_ key: String, _ selector: Selector, tabs: Set<Tab>) {
            let control = button(key, selector)
            actions.addArrangedSubview(control)
            control.widthAnchor.constraint(equalTo: actions.widthAnchor).isActive = true
            control.heightAnchor.constraint(equalToConstant: 24).isActive = true
            actionButtons.append((control, tabs))
        }
        addAction("Find Next", #selector(findNextPressed), tabs: [.find, .replace])
        addAction("Count matches", #selector(countPressed), tabs: [.find])
        addAction("Replace", #selector(replacePressed), tabs: [.replace])
        actionButtons.last?.0.setAccessibilityIdentifier("duckpad.search.replace-current")
        addAction("Replace All", #selector(replaceAllPressed), tabs: [.replace])
        addAction("Find all in current document", #selector(findAllPressed), tabs: [.find])
        addAction("Find all in open documents", #selector(findAllDocumentsPressed), tabs: [.find])
        addAction("Find All", #selector(findInFolderPressed), tabs: [.folder])
        addAction("Bookmark matching lines", #selector(markAllPressed), tabs: [.bookmarks])
        addAction("Clear All Bookmarks", #selector(clearBookmarksPressed), tabs: [.bookmarks])
        addAction("Close", #selector(closePressed), tabs: [.find, .replace, .folder, .bookmarks])
        actionButtons.last?.0.keyEquivalent = "\u{1b}"
        actionButtons.last?.0.setAccessibilityIdentifier("duckpad.search.close")
        actions.widthAnchor.constraint(equalToConstant: 194).isActive = true
        let right = NSView()
        actions.translatesAutoresizingMaskIntoConstraints = false
        appearanceOptions.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(actions)
        right.addSubview(appearanceOptions)
        NSLayoutConstraint.activate([
            right.widthAnchor.constraint(equalTo: actions.widthAnchor),
            actions.topAnchor.constraint(equalTo: right.topAnchor),
            actions.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            appearanceOptions.topAnchor.constraint(greaterThanOrEqualTo: actions.bottomAnchor, constant: 12),
            appearanceOptions.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            appearanceOptions.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            appearanceOptions.bottomAnchor.constraint(equalTo: right.bottomAnchor),
        ])
        let body = horizontal([left, right], spacing: 16)
        body.alignment = .top
        right.heightAnchor.constraint(equalTo: left.heightAnchor).isActive = true

        status.setAccessibilityIdentifier("duckpad.search.status")
        status.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelButton.setAccessibilityIdentifier("duckpad.search.cancel")
        cancelButton.isHidden = true
        let footer = horizontal([status, cancelButton])
        footer.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let separator = NSBox()
        separator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(resultActivated)
        table.onReturn = { [weak self] in self?.activateSelectedResult() }
        table.setAccessibilityIdentifier("duckpad.search.results")
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        resultsScroll.documentView = table
        resultsScroll.hasVerticalScroller = true
        resultsScroll.autohidesScrollers = true
        resultsScroll.borderType = .bezelBorder
        resultsScroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        resultsScroll.isHidden = true

        let header = NSView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: header.topAnchor),
            tabs.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
        ])
        let stack = vertical([header, separator, body, footer, resultsScroll], spacing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        for view in [separator, body, footer, resultsScroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refreshLocalization()
        updateTab()
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        appearanceOptions.refreshLocalization(catalog: catalog)
        for (index, key) in ["Find", "Replace", "Find in Files", "Bookmarks"].enumerated() { tabs.setLabel(localized(key), forSegment: index) }
        tabs.setAccessibilityLabel(localized("Search"))
        for (button, key) in localizedButtons { button.title = localized(key) }
        for (label, key) in localizedLabels { label.stringValue = localized(key) }
        for (field, key) in [(findField as NSTextField, "Find"), (replaceField, "Replace with"), (directoryField, "Directory")] {
            field.placeholderString = localized(key)
            field.setAccessibilityLabel(localized(key))
        }
        for (button, key) in zip(modeButtons, ["Normal", "Extended", "Regex"]) { button.title = localized(key) }
        for (button, key) in [(matchCase, "Match case"), (wholeWord, "Whole word"), (wrap, "Wrap"),
                              (inSelection, "In selection"), (dotMatchesNewline, ". matches newline")] { button.title = localized(key) }
        clearPrevious.title = localized("Clear previous bookmarks")
        modeBox.title = localized("Search mode")
        backwards.title = localized("Search backwards")
        folderHint.stringValue = localized("Search includes subfolders. Hidden files, packages, and symbolic links are skipped.")
        if folderURL == nil { directoryField.stringValue = localized("Choose a folder…") }
        table.tableColumns.first?.title = localized("Search Results")
        let selection = table.selectedRowIndexes
        if let openResult { renderRows(openResult) }
        table.reloadData()
        table.selectRowIndexes(selection, byExtendingSelection: false)
        if let statusRenderer { status.stringValue = statusRenderer(catalog) }
        onLayoutChanged?()
    }

    var windowTitle: String {
        localized(["Find", "Replace", "Find in Files", "Bookmarks"][selectedTab.rawValue])
    }

    func setSearchInProgress(_ isRunning: Bool) {
        // A pending typing refresh must not replace an explicit Find All or navigation.
        if isRunning { incrementalTask?.cancel() }
        cancelButton.isHidden = !isRunning
    }

    func applyPreferences(_ settings: AppSettings) {
        let font = settings.monospacedFindFields
            ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 13)
        findField.font = font
        replaceField.font = font
    }

    func show(replace: Bool, selectedText: String? = nil) {
        show(tab: replace ? .replace : .find, selectedText: selectedText)
    }

    func show(tab: Tab, selectedText: String? = nil) {
        incrementalTask?.cancel()
        if let selectedText, !selectedText.isEmpty, selectedText != findField.stringValue {
            onQueryInvalidated?()
            findField.stringValue = selectedText
            clearResults()
        }
        if selectedTab != tab {
            onQueryInvalidated?()
            clearResults()
        }
        selectedTab = tab
        tabs.selectedSegment = tab.rawValue
        updateTab()
        isHidden = false
        onLayoutChanged?()
        focusFind()
        scheduleIncrementalQuery()
    }

    func setFolderURL(_ url: URL) {
        folderURL = url
        directoryField.stringValue = url.path
        directoryField.toolTip = url.path
    }

    func currentQuery(direction: SearchDirection? = nil) -> SearchQuery {
        SearchQuery(pattern: findField.stringValue, replacement: replaceField.stringValue, options: SearchOptions(
            mode: SearchMode.allCases[modeButtons.firstIndex { $0.state == .on } ?? 0],
            matchCase: matchCase.state == .on,
            wholeWord: wholeWord.state == .on,
            dotMatchesNewline: modeButtons[2].state == .on && dotMatchesNewline.state == .on,
            wrapAround: wrap.state == .on,
            direction: direction ?? (backwards.state == .on ? .backward : .forward),
            scope: selectedTab != .folder && inSelection.state == .on ? .selection : .document
        ))
    }

    func present(_ result: SearchResultSet, showsResults: Bool = true) {
        openResult = result
        folderResult = nil
        folderRowOffsets = []
        renderRows(result)
        table.reloadData()
        resultsScroll.isHidden = !showsResults || rows.isEmpty
        onLayoutChanged?()
        statusRenderer = { catalog in
            result.isTruncated
                ? catalog.text("%1$@+ matches (truncated)", arguments: [String(result.matchCount)])
                : catalog.text("search.matches", arguments: [result.matchCount])
        }
        status.stringValue = statusRenderer?(catalog) ?? ""
    }

    private func renderRows(_ result: SearchResultSet) {
        rows = result.documents.flatMap { document in
            [(localized("%1$@ — %2$@", document.title, localized("search.matches", document.matches.count)), nil)]
                + document.matches.map { ("  \($0.line):\($0.column)  \($0.snippet)", Optional(.openDocument($0))) }
        }
    }

    func present(_ result: FolderSearchResultSet) {
        openResult = nil
        rows = []
        folderResult = result
        folderRowOffsets = []
        folderRowOffsets.reserveCapacity(result.documents.count)
        var nextOffset = 0
        for document in result.documents {
            folderRowOffsets.append(nextOffset)
            nextOffset += document.matches.count + 1
        }
        table.reloadData()
        resultsScroll.isHidden = nextOffset == 0
        onLayoutChanged?()
        statusRenderer = { catalog in
            catalog.text(result.isTruncated
                ? "Matches: %1$@+ · Files: %2$@ · Skipped: %3$@ (results truncated)"
                : "Matches: %1$@ · Files: %2$@ · Skipped: %3$@",
                arguments: [String(result.matchCount), String(result.searchedFileCount), String(result.skippedFileCount)])
        }
        status.stringValue = statusRenderer?(catalog) ?? ""
    }

    func presentStatus(_ message: String) {
        statusRenderer = nil
        status.stringValue = message
    }

    func presentStatus(key: String, arguments: [CVarArg] = []) {
        statusRenderer = { $0.text(key, arguments: arguments) }
        status.stringValue = statusRenderer?(catalog) ?? ""
    }

    func presentFailure(prefix: String, error: any Error) {
        statusRenderer = { catalog in
            catalog.text(prefix, arguments: [PresentationErrorText.message(error, catalog: catalog)])
        }
        status.stringValue = statusRenderer?(catalog) ?? ""
    }
    func focusFind() { window?.makeFirstResponder(findField) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)) where control === findField:
            primaryPressed()
        case #selector(NSResponder.cancelOperation(_:)):
            closePressed()
        default:
            return false
        }
        return true
    }

    // Refresh after an edit/tab change without interrupting the edit or replacement publishing that change.
    func refreshMatchesAfterDocumentChange() {
        guard !isHidden, selectedTab != .folder else { return }
        scheduleIncrementalQuery()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === findField else { return }
        queryChanged()
    }

    @objc private func tabChanged() {
        selectedTab = Tab(rawValue: tabs.selectedSegment) ?? .find
        updateTab()
        queryChanged()
        focusFind()
    }

    private func updateTab() {
        clearPrevious.isHidden = selectedTab != .bookmarks
        replacementRow.isHidden = selectedTab != .replace
        directoryRow.isHidden = selectedTab != .folder
        folderHint.isHidden = selectedTab != .folder
        inSelection.isHidden = selectedTab == .folder
        wrap.isHidden = selectedTab == .folder
        backwards.isHidden = selectedTab == .folder
        let primary = actionButtons.first { $0.1.contains(selectedTab) }?.0
        for (button, visibleTabs) in actionButtons {
            button.isHidden = !visibleTabs.contains(selectedTab)
            if button.action != #selector(closePressed) { button.keyEquivalent = button === primary ? "\r" : "" }
        }
        onLayoutChanged?()
    }

    @objc private func modeChanged(_ sender: NSButton) {
        for button in modeButtons { button.state = button === sender ? .on : .off }
        dotMatchesNewline.isEnabled = sender.tag == 2
        queryChanged()
    }

    @objc private func optionsChanged() { queryChanged() }

    private func clearResults() {
        openResult = nil
        statusRenderer = nil
        rows = []
        folderResult = nil
        folderRowOffsets = []
        table.reloadData()
        resultsScroll.isHidden = true
        status.stringValue = ""
        onLayoutChanged?()
    }

    private func queryChanged() {
        incrementalTask?.cancel()
        onQueryInvalidated?()
        clearResults()
        scheduleIncrementalQuery()
    }

    private func scheduleIncrementalQuery() {
        incrementalTask?.cancel()
        guard !findField.stringValue.isEmpty, selectedTab != .folder else { return }
        incrementalTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, !self.findField.stringValue.isEmpty else { return }
            self.onIncrementalQuery?(self.currentQuery())
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let result = folderResult else { return rows.count }
        return result.matchCount + result.documents.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label: String
        if let (documentIndex, matchIndex) = folderLocation(forRow: row), let result = folderResult {
            let document = result.documents[documentIndex]
            if let matchIndex {
                let match = document.matches[matchIndex]
                label = "  \(match.line):\(match.column)  \(match.snippet)"
            } else {
                label = localized("%1$@ — %2$@", document.relativePath, localized("search.matches", document.matches.count))
            }
        } else {
            label = rows[row].0
        }
        let field = NSTextField(labelWithString: label)
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(label)
        return field
    }

    @objc private func primaryPressed() {
        if selectedTab == .folder { findInFolderPressed() }
        else if selectedTab == .bookmarks { markAllPressed() }
        else { findNextPressed() }
    }
    @objc private func findNextPressed() { incrementalTask?.cancel(); onFind?(currentQuery()) }
    @objc private func countPressed() { incrementalTask?.cancel(); onIncrementalQuery?(currentQuery()) }
    @objc private func findPreviousPressed() { incrementalTask?.cancel(); onFind?(currentQuery(direction: .backward)) }
    @objc private func replacePressed() { incrementalTask?.cancel(); onReplace?(currentQuery()) }
    @objc private func replaceAllPressed() { incrementalTask?.cancel(); onReplaceAll?(currentQuery()) }
    @objc private func findAllPressed() { incrementalTask?.cancel(); onFindAll?(currentQuery()) }
    @objc private func findAllDocumentsPressed() {
        incrementalTask?.cancel()
        var query = currentQuery()
        query.options.scope = .allOpenDocuments
        onFindAll?(query)
    }
    @objc private func markAllPressed() { incrementalTask?.cancel(); onMarkAll?(currentQuery(), clearPrevious.state == .on) }
    @objc private func clearBookmarksPressed() { incrementalTask?.cancel(); onClearBookmarks?() }
    @objc private func chooseFolderPressed() { onChooseFolder?() }
    @objc private func findInFolderPressed() { incrementalTask?.cancel(); onFindInFolder?(currentQuery()) }
    @objc private func cancelPressed() {
        incrementalTask?.cancel()
        presentStatus(key: "Cancelled")
        onCancel?()
    }
    @objc private func closePressed() { hide(); onClose?() }
    override func cancelOperation(_ sender: Any?) { closePressed() }

    @objc private func resultActivated() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 else { return }
        if let (documentIndex, matchIndex) = folderLocation(forRow: row),
           let matchIndex,
           let result = folderResult {
            let document = result.documents[documentIndex]
            onActivateFolderMatch?(document, document.matches[matchIndex])
            return
        }
        guard row < rows.count, let target = rows[row].1 else { return }
        switch target {
        case .openDocument(let match): onActivateMatch?(match)
        }
    }

    func hide() {
        incrementalTask?.cancel()
        isHidden = true
    }

    private func activateSelectedResult() { resultActivated() }

    private func folderLocation(forRow row: Int) -> (document: Int, match: Int?)? {
        guard folderResult != nil, row >= 0, !folderRowOffsets.isEmpty else { return nil }
        var lower = 0
        var upper = folderRowOffsets.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if folderRowOffsets[middle] <= row { lower = middle + 1 }
            else { upper = middle }
        }
        let document = lower - 1
        guard document >= 0 else { return nil }
        let offset = row - folderRowOffsets[document]
        return (document, offset == 0 ? nil : offset - 1)
    }

    private func button(_ key: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: localized(key), target: self, action: action)
        localizedButtons.append((button, key))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        return button
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func fieldRow(_ key: String, field: NSView) -> NSStackView {
        let row = NSStackView()
        configureFieldRow(row, key: key, field: field)
        return row
    }

    private func configureFieldRow(_ row: NSStackView, key: String, field: NSView) {
        let label = NSTextField(labelWithString: localized(key))
        label.alignment = .right
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true
        localizedLabels.append((label, key))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
    }

    private func configureBox(_ box: NSBox, content: NSView) {
        box.boxType = .primary
        box.titleFont = .systemFont(ofSize: 12, weight: .medium)
        box.contentViewMargins = NSSize(width: 8, height: 6)
        box.contentView = NSView()
        guard let container = box.contentView else { return }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
