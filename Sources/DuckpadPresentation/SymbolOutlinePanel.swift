import AppKit
import DuckpadApplication

@MainActor
struct SymbolOutlineSearch {
    static func matchingIndices(in symbols: [DocumentSymbol], query: String) -> [Int] {
        let terms = folded(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return Array(symbols.indices) }
        return symbols.indices.filter { index in
            let symbol = symbols[index]
            let searchable = folded("\(symbol.name) \(symbol.kind.rawValue) \(symbol.line)")
            return terms.allSatisfy(searchable.contains)
        }
    }

    private static func folded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

@MainActor
final class SymbolOutlinePanel: NSObject,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate
{
    var onActivate: ((DocumentSymbol) -> Void)?

    private(set) var symbols: [DocumentSymbol] = []
    private(set) var filteredIndices: [Int] = []
    private let searchField = NSSearchField(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let emptyLabel = NSTextField(labelWithString: "No symbols in this document")
    private let countLabel = NSTextField(labelWithString: "")
    private let contentController = NSViewController()
    private let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: 360))
    private var popover: NSPopover?
    private weak var hostWindow: NSWindow?

    var isPresented: Bool { popover?.isShown == true }
    var filteredSymbols: [DocumentSymbol] { filteredIndices.map { symbols[$0] } }

    override init() {
        super.init()
        rootView.setAccessibilityIdentifier("duckpad.symbols.panel")

        searchField.placeholderString = "Search symbols"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("duckpad.symbols.search")
        searchField.setAccessibilityLabel("Search current document symbols")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("symbol"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelection)
        tableView.setAccessibilityIdentifier("duckpad.symbols.results")
        tableView.setAccessibilityLabel("Current document symbol results")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.setAccessibilityIdentifier("duckpad.symbols.empty")

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

    func apply(symbols: [DocumentSymbol]) {
        self.symbols = symbols
        refilter()
    }

    func present(symbols: [DocumentSymbol], relativeTo positioningView: NSView) {
        guard let window = positioningView.window else { return }
        searchField.stringValue = ""
        apply(symbols: symbols)
        stopObservingHostWindow()
        hostWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        let height = min(CGFloat(420), max(CGFloat(150), CGFloat(74 + min(symbols.count, 10) * 31)))
        rootView.frame.size = NSSize(width: 390, height: height)
        if popover?.isShown != true {
            let next = NSPopover()
            next.behavior = .transient
            next.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            next.delegate = self
            next.contentSize = rootView.frame.size
            next.contentViewController = contentController
            popover = next
            next.show(relativeTo: positioningView.bounds, of: positioningView, preferredEdge: .minY)
        }
        contentController.view.window?.makeFirstResponder(searchField)
    }

    func dismiss() {
        stopObservingHostWindow()
        let closing = popover
        popover = nil
        closing?.close()
    }

    func setQuery(_ query: String) {
        searchField.stringValue = query
        refilter()
    }

    func selectResult(at index: Int) {
        guard filteredIndices.indices.contains(index) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    func activateSelectedResult() { activateSelection() }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredIndices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredIndices.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SymbolOutlineCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        let symbol = symbols[filteredIndices[row]]
        cell.textField?.stringValue = symbol.name
        cell.imageView?.image = NSImage(
            systemSymbolName: imageName(for: symbol.kind),
            accessibilityDescription: nil
        )
        cell.toolTip = "\(symbol.kind.rawValue.capitalized), line \(symbol.line)"
        cell.setAccessibilityLabel(
            "\(symbol.name), \(symbol.kind.rawValue), line \(symbol.line)"
        )
        if let detail = cell.viewWithTag(42) as? NSTextField {
            detail.stringValue = "Line \(symbol.line)"
        }
        return cell
    }

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        if let closed = notification.object as? NSPopover, popover === closed { popover = nil }
        stopObservingHostWindow()
        searchField.stringValue = ""
    }

    @objc private func hostWindowWillClose(_ notification: Notification) { dismiss() }

    @objc private func activateSelection() {
        let row = tableView.selectedRow
        guard filteredIndices.indices.contains(row) else { return }
        let symbol = symbols[filteredIndices[row]]
        dismiss()
        onActivate?(symbol)
    }

    private func refilter() {
        filteredIndices = SymbolOutlineSearch.matchingIndices(in: symbols, query: searchField.stringValue)
        tableView.reloadData()
        emptyLabel.isHidden = !filteredIndices.isEmpty
        countLabel.stringValue = "\(filteredIndices.count) of \(symbols.count)"
        if !filteredIndices.isEmpty { selectResult(at: 0) }
    }

    private func moveSelection(by offset: Int) {
        guard !filteredIndices.isEmpty else { return }
        let current = max(0, tableView.selectedRow)
        selectResult(at: min(max(0, current + offset), filteredIndices.count - 1))
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView(frame: .zero)
        cell.identifier = identifier
        let icon = NSImageView(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(labelWithString: "")
        detail.tag = 42
        detail.textColor = .tertiaryLabelColor
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = icon
        cell.textField = title
        cell.addSubview(icon)
        cell.addSubview(title)
        cell.addSubview(detail)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func imageName(for kind: DocumentSymbolKind) -> String {
        switch kind {
        case .type: "cube"
        case .function: "function"
        case .property: "p.square"
        case .heading: "textformat.size"
        case .section: "list.bullet.rectangle"
        }
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
}
