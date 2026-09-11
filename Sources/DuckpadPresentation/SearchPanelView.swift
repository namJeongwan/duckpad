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
    private enum ResultTarget {
        case openDocument(SearchMatch)
    }

    var onFind: ((SearchQuery) -> Void)?
    var onReplace: ((SearchQuery) -> Void)?
    var onReplaceAll: ((SearchQuery) -> Void)?
    var onFindAll: ((SearchQuery) -> Void)?
    var onFindInFolder: ((SearchQuery) -> Void)?
    var onIncrementalQuery: ((SearchQuery) -> Void)?
    var onQueryInvalidated: (() -> Void)?
    var onActivateMatch: ((SearchMatch) -> Void)?
    var onActivateFolderMatch: ((FolderSearchDocumentResult, FolderSearchMatch) -> Void)?
    var onClose: (() -> Void)?
    var onCancel: (() -> Void)?

    private let findField = NSSearchField()
    private let replaceField = NSTextField()
    private let mode = NSSegmentedControl(labels: [L10n.text("Normal"), L10n.text("Extended"), L10n.text("Regex")], trackingMode: .selectOne, target: nil, action: nil)
    private let matchCase = NSButton(checkboxWithTitle: L10n.text("Match case"), target: nil, action: nil)
    private let wholeWord = NSButton(checkboxWithTitle: L10n.text("Whole word"), target: nil, action: nil)
    private let dotMatchesNewline = NSButton(checkboxWithTitle: L10n.text(". matches newline"), target: nil, action: nil)
    private let wrap = NSButton(checkboxWithTitle: L10n.text("Wrap"), target: nil, action: nil)
    private let inSelection = NSButton(checkboxWithTitle: L10n.text("In selection"), target: nil, action: nil)
    private let allDocuments = NSButton(checkboxWithTitle: L10n.text("All open documents"), target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let table = SearchResultsTable()
    private let resultsScroll = NSScrollView()
    private var rows: [(String, ResultTarget?)] = []
    private var openResult: SearchResultSet?
    private var statusRenderer: ((LocalizationCatalog) -> String)?
    private var localizedButtons: [(NSButton, String)] = []
    private var folderResult: FolderSearchResultSet?
    private var folderRowOffsets: [Int] = []
    private var incrementalTask: Task<Void, Never>?
    private var showingReplace = false
    private lazy var collapsedHeight = heightAnchor.constraint(equalToConstant: 0)
    private var expandedVerticalConstraints: [NSLayoutConstraint] = []

    private var catalog = L10n.catalog

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        catalog.text(key, arguments: arguments)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("duckpad.search.panel")
        mode.selectedSegment = 0
        wrap.state = .on
        findField.placeholderString = localized("Find")
        findField.delegate = self
        findField.setAccessibilityIdentifier("duckpad.search.find")
        replaceField.placeholderString = localized("Replace with")
        replaceField.delegate = self
        replaceField.setAccessibilityIdentifier("duckpad.search.replace")
        status.setAccessibilityIdentifier("duckpad.search.status")
        status.lineBreakMode = .byTruncatingTail

        let findNext = button("Next", #selector(findNextPressed))
        let findPrevious = button("Previous", #selector(findPreviousPressed))
        let replace = button("Replace", #selector(replacePressed))
        replace.setAccessibilityIdentifier("duckpad.search.replace-current")
        let replaceAll = button("Replace All", #selector(replaceAllPressed))
        let findAll = button("Find All", #selector(findAllPressed))
        let findInFolder = button("Folder…", #selector(findInFolderPressed))
        findInFolder.setAccessibilityLabel(localized("Find in Folder"))
        let cancel = button("Cancel", #selector(cancelPressed))
        let close = button("×", #selector(closePressed))
        close.setAccessibilityLabel(localized("Close Find and Replace"))

        let top = NSStackView(views: [findField, replaceField, findNext, findPrevious, replace, replaceAll, findAll, findInFolder, cancel, close])
        top.orientation = .horizontal
        top.spacing = 6
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        let options = NSStackView(views: [mode, matchCase, wholeWord, dotMatchesNewline, wrap, inSelection, allDocuments, status])
        options.orientation = .horizontal
        options.spacing = 10

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.title = localized("Search Results")
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(resultActivated)
        table.onReturn = { [weak self] in self?.activateSelectedResult() }
        table.setAccessibilityIdentifier("duckpad.search.results")
        resultsScroll.documentView = table
        resultsScroll.hasVerticalScroller = true
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true

        let controls = NSStackView(views: [top, options])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false
        let controlsScroll = NSScrollView()
        controlsScroll.documentView = controls
        controlsScroll.hasHorizontalScroller = true
        controlsScroll.autohidesScrollers = true
        controlsScroll.drawsBackground = false
        controlsScroll.translatesAutoresizingMaskIntoConstraints = false
        controlsScroll.heightAnchor.constraint(equalToConstant: 70).isActive = true
        let stack = NSStackView(views: [controlsScroll, resultsScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        expandedVerticalConstraints = [
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            controls.widthAnchor.constraint(greaterThanOrEqualTo: controlsScroll.contentView.widthAnchor),
            resultsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
        ] + expandedVerticalConstraints)
        replaceField.isHidden = true
        replace.isHidden = true
        replaceAll.isHidden = true
        resultsScroll.isHidden = true
        NSLayoutConstraint.deactivate(expandedVerticalConstraints)
        isHidden = true
        collapsedHeight.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        findField.placeholderString = localized("Find")
        replaceField.placeholderString = localized("Replace with")
        for (index, key) in ["Normal", "Extended", "Regex"].enumerated() {
            mode.setLabel(localized(key), forSegment: index)
        }
        for (button, key) in [(matchCase, "Match case"), (wholeWord, "Whole word"),
                              (dotMatchesNewline, ". matches newline"), (wrap, "Wrap"),
                              (inSelection, "In selection"), (allDocuments, "All open documents")] {
            button.title = localized(key)
        }
        for (button, key) in localizedButtons { button.title = localized(key) }
        subviewsRecursiveButtons(actions: [#selector(findInFolderPressed)]).first?
            .setAccessibilityLabel(localized("Find in Folder"))
        subviewsRecursiveButtons(actions: [#selector(closePressed)]).first?
            .setAccessibilityLabel(localized("Close Find and Replace"))
        table.tableColumns.first?.title = localized("Search Results")
        let selection = table.selectedRowIndexes
        if let openResult { renderRows(openResult) }
        table.reloadData()
        table.selectRowIndexes(selection, byExtendingSelection: false)
        if let statusRenderer { status.stringValue = statusRenderer(catalog) }
    }

    func applyPreferences(_ settings: AppSettings) {
        let font = settings.monospacedFindFields
            ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 13)
        findField.font = font
        replaceField.font = font
    }

    func show(replace: Bool, selectedText: String? = nil) {
        if let selectedText, !selectedText.isEmpty, selectedText != findField.stringValue {
            incrementalTask?.cancel()
            onQueryInvalidated?()
            findField.stringValue = selectedText
            openResult = nil
            statusRenderer = nil
            rows = []
            folderResult = nil
            folderRowOffsets = []
            table.reloadData()
            resultsScroll.isHidden = true
            status.stringValue = ""
        }
        showingReplace = replace
        allDocuments.isEnabled = !replace
        if replace { allDocuments.state = .off }
        replaceField.isHidden = !replace
        subviewsRecursiveButtons(actions: [#selector(replacePressed), #selector(replaceAllPressed)]).forEach { $0.isHidden = !replace }
        NSLayoutConstraint.activate(expandedVerticalConstraints)
        isHidden = false
        collapsedHeight.constant = 88
        window?.makeFirstResponder(findField)
    }

    func currentQuery(direction: SearchDirection = .forward) -> SearchQuery {
        var options = SearchOptions(
            mode: SearchMode.allCases[mode.selectedSegment],
            matchCase: matchCase.state == .on,
            wholeWord: wholeWord.state == .on,
            dotMatchesNewline: dotMatchesNewline.state == .on,
            wrapAround: wrap.state == .on,
            direction: direction,
            scope: allDocuments.state == .on ? .allOpenDocuments : (inSelection.state == .on ? .selection : .document)
        )
        if direction == .backward { options.direction = .backward }
        return SearchQuery(pattern: findField.stringValue, replacement: replaceField.stringValue, options: options)
    }

    func present(_ result: SearchResultSet) {
        openResult = result
        folderResult = nil
        folderRowOffsets = []
        renderRows(result)
        table.reloadData()
        resultsScroll.isHidden = rows.isEmpty
        collapsedHeight.constant = rows.isEmpty ? 88 : 224
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
        collapsedHeight.constant = nextOffset == 0 ? 88 : 224
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

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === findField else { return }
        incrementalTask?.cancel()
        onQueryInvalidated?()
        if findField.stringValue.isEmpty {
            openResult = nil
            statusRenderer = nil
            rows = []
            folderResult = nil
            folderRowOffsets = []
            table.reloadData()
            resultsScroll.isHidden = true
            collapsedHeight.constant = 88
            status.stringValue = ""
            return
        }
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

    @objc private func findNextPressed() { onFind?(currentQuery()) }
    @objc private func findPreviousPressed() { onFind?(currentQuery(direction: .backward)) }
    @objc private func replacePressed() { onReplace?(currentQuery()) }
    @objc private func replaceAllPressed() { onReplaceAll?(currentQuery()) }
    @objc private func findAllPressed() { onFindAll?(currentQuery()) }
    @objc private func findInFolderPressed() { onFindInFolder?(currentQuery()) }
    @objc private func cancelPressed() { presentStatus(key: "Cancelled"); onCancel?() }
    @objc private func closePressed() { hide(); onClose?() }
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
        resultsScroll.isHidden = true
        NSLayoutConstraint.deactivate(expandedVerticalConstraints)
        collapsedHeight.constant = 0
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
        return button
    }

    private func subviewsRecursiveButtons(actions: Set<Selector>) -> [NSButton] {
        func collect(_ view: NSView) -> [NSButton] {
            let own = (view as? NSButton).map { $0.action.map(actions.contains) == true ? [$0] : [] } ?? []
            return own + view.subviews.flatMap(collect)
        }
        return collect(self)
    }
}
