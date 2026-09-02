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
    var onFind: ((SearchQuery) -> Void)?
    var onReplace: ((SearchQuery) -> Void)?
    var onReplaceAll: ((SearchQuery) -> Void)?
    var onFindAll: ((SearchQuery) -> Void)?
    var onIncrementalQuery: ((SearchQuery) -> Void)?
    var onQueryInvalidated: (() -> Void)?
    var onActivateMatch: ((SearchMatch) -> Void)?
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
    private var rows: [(String, SearchMatch?)] = []
    private var incrementalTask: Task<Void, Never>?
    private var showingReplace = false
    private lazy var collapsedHeight = heightAnchor.constraint(equalToConstant: 0)

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
        let cancel = button("Cancel", #selector(cancelPressed))
        let close = button("×", #selector(closePressed))
        close.setAccessibilityLabel("Close Find and Replace")

        let top = NSStackView(views: [findField, replaceField, findNext, findPrevious, replace, replaceAll, findAll, cancel, close])
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
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            options.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            resultsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
        ])
        replaceField.isHidden = true
        replace.isHidden = true
        replaceAll.isHidden = true
        resultsScroll.isHidden = true
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
        rows = result.documents.flatMap { document in
            [("\(document.title) — \(document.matches.count) match(es)", nil)]
                + document.matches.map { ("  \($0.line):\($0.column)  \($0.snippet)", Optional($0)) }
        }
        table.reloadData()
        resultsScroll.isHidden = rows.isEmpty
        collapsedHeight.constant = rows.isEmpty ? 76 : 212
        status.stringValue = result.isTruncated
            ? "\(result.matchCount)+ matches (truncated)"
            : "\(result.matchCount) matches"
    }

    func presentStatus(_ message: String) { status.stringValue = message }
    func focusFind() { window?.makeFirstResponder(findField) }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === findField else { return }
        incrementalTask?.cancel()
        onQueryInvalidated?()
        if findField.stringValue.isEmpty {
            rows = []
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

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: rows[row].0)
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(rows[row].0)
        return field
    }

    @objc private func findNextPressed() { onFind?(currentQuery()) }
    @objc private func findPreviousPressed() { onFind?(currentQuery(direction: .backward)) }
    @objc private func replacePressed() { onReplace?(currentQuery()) }
    @objc private func replaceAllPressed() { onReplaceAll?(currentQuery()) }
    @objc private func findAllPressed() { onFindAll?(currentQuery()) }
    @objc private func cancelPressed() { status.stringValue = "Cancelled"; onCancel?() }
    @objc private func closePressed() { hide(); onClose?() }
    @objc private func resultActivated() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, let match = rows[row].1 else { return }
        onActivateMatch?(match)
    }

    func hide() {
        incrementalTask?.cancel()
        resultsScroll.isHidden = true
        collapsedHeight.constant = 0
        isHidden = true
    }

    private func activateSelectedResult() { resultActivated() }

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
