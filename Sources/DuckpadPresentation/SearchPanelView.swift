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
    private let mode = NSSegmentedControl(labels: ["Normal", "Extended", "Regex"], trackingMode: .selectOne, target: nil, action: nil)
    private let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let wholeWord = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    private let dotMatchesNewline = NSButton(checkboxWithTitle: ". matches newline", target: nil, action: nil)
    private let wrap = NSButton(checkboxWithTitle: "Wrap", target: nil, action: nil)
    private let inSelection = NSButton(checkboxWithTitle: "In selection", target: nil, action: nil)
    private let allDocuments = NSButton(checkboxWithTitle: "All open documents", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let table = SearchResultsTable()
    private let resultsScroll = NSScrollView()
    private var rows: [(String, ResultTarget?)] = []
    private var folderResult: FolderSearchResultSet?
    private var folderRowOffsets: [Int] = []
    private var incrementalTask: Task<Void, Never>?
    private var showingReplace = false
    private lazy var collapsedHeight = heightAnchor.constraint(equalToConstant: 0)
    private var expandedVerticalConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("duckpad.search.panel")
        mode.selectedSegment = 0
        wrap.state = .on
        findField.placeholderString = "Find"
        findField.delegate = self
        findField.setAccessibilityIdentifier("duckpad.search.find")
        replaceField.placeholderString = "Replace with"
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
        findInFolder.setAccessibilityLabel("Find in Folder")
        let cancel = button("Cancel", #selector(cancelPressed))
        let close = button("×", #selector(closePressed))
        close.setAccessibilityLabel("Close Find and Replace")

        let top = NSStackView(views: [findField, replaceField, findNext, findPrevious, replace, replaceAll, findAll, findInFolder, cancel, close])
        top.orientation = .horizontal
        top.spacing = 6
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        let options = NSStackView(views: [mode, matchCase, wholeWord, dotMatchesNewline, wrap, inSelection, allDocuments, status])
        options.orientation = .horizontal
        options.spacing = 10

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.title = "Search Results"
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

        let stack = NSStackView(views: [top, options, resultsScroll])
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
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            options.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
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

    func show(replace: Bool) {
        showingReplace = replace
        allDocuments.isEnabled = !replace
        if replace { allDocuments.state = .off }
        replaceField.isHidden = !replace
        subviewsRecursiveButtons(named: ["Replace", "Replace All"]).forEach { $0.isHidden = !replace }
        NSLayoutConstraint.activate(expandedVerticalConstraints)
        isHidden = false
        collapsedHeight.constant = 76
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
        folderResult = nil
        folderRowOffsets = []
        rows = result.documents.flatMap { document in
            [("\(document.title) — \(document.matches.count) match(es)", nil)]
                + document.matches.map { ("  \($0.line):\($0.column)  \($0.snippet)", Optional(.openDocument($0))) }
        }
        table.reloadData()
        resultsScroll.isHidden = rows.isEmpty
        collapsedHeight.constant = rows.isEmpty ? 76 : 212
        status.stringValue = result.isTruncated
            ? "\(result.matchCount)+ matches (truncated)"
            : "\(result.matchCount) matches"
    }

    func present(_ result: FolderSearchResultSet) {
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
        collapsedHeight.constant = nextOffset == 0 ? 76 : 212
        let suffix = result.skippedFileCount > 0 ? "; \(result.skippedFileCount) skipped" : ""
        status.stringValue = result.isTruncated
            ? "\(result.matchCount)+ matches in \(result.searchedFileCount) files (truncated\(suffix))"
            : "\(result.matchCount) matches in \(result.searchedFileCount) files\(suffix)"
    }

    func presentStatus(_ message: String) { status.stringValue = message }
    func focusFind() { window?.makeFirstResponder(findField) }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === findField else { return }
        incrementalTask?.cancel()
        onQueryInvalidated?()
        if findField.stringValue.isEmpty {
            rows = []
            folderResult = nil
            folderRowOffsets = []
            table.reloadData()
            resultsScroll.isHidden = true
            collapsedHeight.constant = 76
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
                label = "\(document.relativePath) — \(document.matches.count) match(es)"
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
    @objc private func cancelPressed() { status.stringValue = "Cancelled"; onCancel?() }
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

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func subviewsRecursiveButtons(named names: Set<String>) -> [NSButton] {
        func collect(_ view: NSView) -> [NSButton] {
            let own = (view as? NSButton).map { names.contains($0.title) ? [$0] : [] } ?? []
            return own + view.subviews.flatMap(collect)
        }
        return collect(self)
    }
}
