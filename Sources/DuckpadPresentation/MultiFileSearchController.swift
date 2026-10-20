import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

/// Project search has its own layout and lifecycle; the classic Find window is untouched.
@MainActor
final class MultiFileSearchController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDelegate, NSTableViewDataSource {
    typealias Progress = @MainActor @Sendable (MultiFileSearchResults) -> Void
    var onSearchRequest: ((SearchQuery, ProjectSearchScope, URL?, @escaping Progress) async throws -> MultiFileSearchResults)?
    var onSearch: ((SearchQuery, URL?) async throws -> MultiFileSearchResults)?
    var onSearchWithProgress: ((SearchQuery, URL?, @escaping Progress) async throws -> MultiFileSearchResults)?
    var onReplace: ((SearchQuery, MultiFileSearchResults) async throws -> OpenDocumentsReplacementResult)?
    var onActivate: ((MultiFileSearchResults.Row.Target) -> Void)?
    var onPreview: ((MultiFileSearchResults.Row.Target) async -> SearchMatchPreview?)?
    var onOpenResults: ((SearchQuery, MultiFileSearchResults) -> Void)?
    var onChooseFolder: (() async -> URL?)?
    private let find = SearchInputField()
    private let replacement = SearchInputField()
    private let replaceRow = NSStackView()
    private let scope = NSSegmentedControl(labels: ["", "", "", ""], trackingMode: .selectOne, target: nil, action: nil)
    private let mode = NSPopUpButton()
    private let matchCase = SearchOptionButton()
    private let wholeWord = SearchOptionButton()
    private let dotNewline = SearchOptionButton()
    private let browse = NSButton()
    private let directory = NSTextField(labelWithString: "")
    private let searchButton = StatusBarButton()
    private let replaceButton = SearchActionButton()
    private let replaceOneButton = SearchActionButton()
    private let maskEnabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let mask = SearchInputField(fontSize: 12, showsUnderline: true)
    private let regex = SearchOptionButton()
    private let clearFind = StatusBarButton()
    private let cancelButton = SearchActionButton()
    private let table = SearchResultTableView()
    private let split = SearchResultsSplitView()
    private let preview = SearchCodePreviewView()
    private let heading = NSTextField(labelWithString: "")
    private let resultCount = NSTextField(labelWithString: "")
    private let openButton = SearchActionButton()
    private let closeButton = StatusBarButton()
    private let previewTitle = NSTextField(labelWithString: "")
    private let previewHint = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "")
    private var catalog = L10n.catalog
    private var includeHiddenFiles = false
    private let dismissal = SearchPopupDismissal()
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var result: MultiFileSearchResults?
    private(set) var rows: [MultiFileSearchResults.Row] = []
    private(set) var isReplacing = false
    private(set) var folder: URL?
    private var hasWorkspace = false
    private var workspaceCount = 0
    private var workspacePaths: [String] = []
    var selectedScope: ProjectSearchScope { ProjectSearchScope(rawValue: scope.selectedSegment) ?? .all }
    private var running = false
    private var applying = false
    private var summary: OpenDocumentsReplacementResult?
    private var statusKey: String = "Type to search in files"
    private var statusArguments: [CVarArg] = []

    init() {
        let panel = SearchPopupPanel(size: .init(width: 960, height: 680), identifier: "duckpad.multifile.window")
        panel.minSize = .init(width: 720, height: 460)
        super.init(window: panel)
        panel.delegate = self
        let root = SearchSurfaceView(.panel)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        resultCount.font = .systemFont(ofSize: 12); resultCount.textColor = .secondaryLabelColor
        resultCount.lineBreakMode = .byTruncatingTail
        resultCount.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.isBordered = false; closeButton.imagePosition = .imageOnly
        closeButton.target = self; closeButton.action = #selector(closePressed)
        closeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        mode.controlSize = .regular; mode.isBordered = false; mode.imagePosition = .imageOnly
        (mode.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        mode.widthAnchor.constraint(equalToConstant: 28).isActive = true
        mode.heightAnchor.constraint(equalToConstant: 28).isActive = true
        mode.target = self; mode.action = #selector(optionsChanged)
        mode.setAccessibilityIdentifier("duckpad.multifile.mode")
        maskEnabled.font = .systemFont(ofSize: 12)
        maskEnabled.setContentCompressionResistancePriority(.required, for: .horizontal)
        maskEnabled.target = self; maskEnabled.action = #selector(optionsChanged)
        maskEnabled.setAccessibilityIdentifier("duckpad.multifile.mask.enabled")
        mask.delegate = self
        mask.placeholderString = "*.swift, *.json"
        mask.setAccessibilityIdentifier("duckpad.multifile.mask")
        mask.widthAnchor.constraint(greaterThanOrEqualToConstant: 136).isActive = true
        mask.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        mask.heightAnchor.constraint(equalToConstant: SearchInputField.preferredHeight).isActive = true
        mask.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = horizontal([heading, resultCount, NSView(), maskEnabled, mask, mode, closeButton])
        titleRow.spacing = 8; titleRow.heightAnchor.constraint(equalToConstant: 36).isActive = true

        for (field, identifier) in [(find, "find"), (replacement, "replace")] {
            field.delegate = self
            field.setAccessibilityIdentifier("duckpad.multifile." + identifier)
            field.heightAnchor.constraint(equalToConstant: SearchInputField.preferredHeight).isActive = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for (button, title, identifier) in [(matchCase, "Cc", "case"), (wholeWord, "W", "word"), (regex, ".*", "regex"), (dotNewline, ".n", "newline")] {
            button.imagePosition = .noImage; button.title = title; button.font = .systemFont(ofSize: 14)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.onToggle = { [weak self, weak button] _ in
                guard let self else { return }
                if button === self.regex { self.regexChanged() } else { self.optionsChanged() }
            }
            button.setAccessibilityIdentifier("duckpad.multifile." + identifier)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        clearFind.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        clearFind.isBordered = false; clearFind.imagePosition = .imageOnly
        clearFind.target = self; clearFind.action = #selector(clearPressed)
        clearFind.widthAnchor.constraint(equalToConstant: 28).isActive = true
        searchButton.image = NSImage(systemSymbolName: "return", accessibilityDescription: nil)
        searchButton.isBordered = false; searchButton.imagePosition = .imageOnly
        searchButton.target = self; searchButton.action = #selector(searchPressed)
        searchButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        searchButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let findRow = inputRow(field: find, identifier: "find", trailing: [clearFind, searchButton, matchCase, wholeWord, regex, dotNewline])
        let replacementInput = inputRow(field: replacement, identifier: "replace", trailing: [])
        replaceRow.orientation = .vertical; replaceRow.alignment = .leading; replaceRow.spacing = 0
        replaceRow.addArrangedSubview(replacementInput)
        replacementInput.widthAnchor.constraint(equalTo: replaceRow.widthAnchor).isActive = true
        scope.selectedSegment = 0; scope.controlSize = .regular; scope.segmentStyle = .rounded
        scope.font = .systemFont(ofSize: 12); scope.target = self; scope.action = #selector(optionsChanged)
        scope.setAccessibilityIdentifier("duckpad.multifile.scope")
        scope.setContentCompressionResistancePriority(.required, for: .horizontal)
        scope.setContentHuggingPriority(.required, for: .horizontal)
        browse.bezelStyle = .inline; browse.font = .systemFont(ofSize: 12); browse.target = self; browse.action = #selector(browsePressed)
        browse.setAccessibilityIdentifier("duckpad.multifile.browse")
        directory.lineBreakMode = .byTruncatingMiddle
        directory.font = .systemFont(ofSize: 12); directory.textColor = .secondaryLabelColor
        directory.setContentHuggingPriority(.defaultLow, for: .horizontal)
        directory.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let scopeRow = horizontal([scope, browse, directory])
        scopeRow.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let inputs = NSStackView(views: [titleRow, separator(), findRow, separator(), replaceRow, separator(), scopeRow])
        inputs.orientation = .vertical; inputs.alignment = .leading; inputs.spacing = 2
        for view in inputs.arrangedSubviews { view.widthAnchor.constraint(equalTo: inputs.widthAnchor).isActive = true }
        find.nextKeyView = replacement; replacement.nextKeyView = mask; mask.nextKeyView = table

        table.addTableColumn(NSTableColumn(identifier: .init("match")))
        table.headerView = nil; table.rowHeight = 26; table.intercellSpacing = .init(width: 0, height: 1)
        table.style = .plain; table.backgroundColor = .clear
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(activateSelection)
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.onDismiss = { [weak self] in self?.dismiss() }
        table.setAccessibilityIdentifier("duckpad.multifile.results")
        let resultsScroll = NSScrollView()
        resultsScroll.documentView = table; resultsScroll.hasVerticalScroller = true
        resultsScroll.autohidesScrollers = true; resultsScroll.drawsBackground = false; resultsScroll.scrollerStyle = .overlay
        previewTitle.font = .systemFont(ofSize: 13, weight: .medium); previewTitle.lineBreakMode = .byTruncatingMiddle
        let previewPane = SearchSurfaceView(.editor)
        let previewHeader = SearchSurfaceView(.chrome)
        previewHeader.setAccessibilityIdentifier("duckpad.multifile.previewHeader")
        previewTitle.translatesAutoresizingMaskIntoConstraints = false; previewHeader.addSubview(previewTitle)
        for view in [previewHeader, preview] { view.translatesAutoresizingMaskIntoConstraints = false; previewPane.addSubview(view) }
        NSLayoutConstraint.activate([
            previewHeader.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor), previewHeader.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            previewHeader.topAnchor.constraint(equalTo: previewPane.topAnchor), previewHeader.heightAnchor.constraint(equalToConstant: 40),
            previewTitle.leadingAnchor.constraint(equalTo: previewHeader.leadingAnchor, constant: 16),
            previewTitle.trailingAnchor.constraint(equalTo: previewHeader.trailingAnchor, constant: -16), previewTitle.centerYAnchor.constraint(equalTo: previewHeader.centerYAnchor),
            preview.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor), preview.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewHeader.bottomAnchor), preview.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor),
        ])
        split.addArrangedSubview(resultsScroll); split.addArrangedSubview(previewPane)
        for button in [replaceButton, replaceOneButton, openButton, cancelButton] {
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true; button.target = self
        }
        replaceButton.action = #selector(replacePressed); replaceButton.setAccessibilityIdentifier("duckpad.multifile.apply")
        replaceOneButton.action = #selector(replaceOnePressed); replaceOneButton.isPrimary = true
        replaceOneButton.setAccessibilityIdentifier("duckpad.multifile.replaceOne")
        openButton.action = #selector(openResultsPressed); openButton.setAccessibilityIdentifier("duckpad.multifile.openResults")
        cancelButton.action = #selector(cancelPressed)
        previewHint.font = .systemFont(ofSize: 11); previewHint.textColor = .secondaryLabelColor
        previewHint.maximumNumberOfLines = 2
        previewHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = SearchSurfaceView(.panel)
        footer.setAccessibilityIdentifier("duckpad.multifile.footer")
        let footerRow = horizontal([previewHint, NSView(), cancelButton, openButton, replaceButton, replaceOneButton])
        footerRow.spacing = 10; footerRow.translatesAutoresizingMaskIntoConstraints = false; footer.addSubview(footerRow)
        NSLayoutConstraint.activate([
            footerRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16), footerRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            footerRow.centerYAnchor.constraint(equalTo: footer.centerYAnchor), footer.heightAnchor.constraint(equalToConstant: 54),
            previewHint.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        status.isHidden = true
        empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor
        let bodyDivider = separator(), footerDivider = separator()
        for view in [inputs, bodyDivider, split, footerDivider, footer, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            inputs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), inputs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            inputs.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            bodyDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor), bodyDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyDivider.topAnchor.constraint(equalTo: inputs.bottomAnchor, constant: 5),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4), split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            split.topAnchor.constraint(equalTo: bodyDivider.bottomAnchor, constant: 4), split.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -2),
            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor), footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: resultsScroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: resultsScroll.centerYAnchor),
        ])
        panel.contentView = root
        refreshLocalization(); updateControls()
    }

    private func inputRow(field: NSTextField, identifier: String, trailing: [NSView]) -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityIdentifier("duckpad.multifile." + identifier + ".icon")
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let row = horizontal([icon, field] + trailing); row.spacing = 12
        row.heightAnchor.constraint(equalToConstant: 38).isActive = true
        return row
    }

    private func separator() -> NSBox { let view = NSBox(); view.boxType = .separator; return view }
    required init?(coder: NSCoder) { nil }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 10; stack.alignment = .centerY
        return stack
    }

    func present(replace: Bool, in parent: NSWindow?, selectedText: String? = nil, defaultFolder: URL? = nil) {
        guard let window else { return }
        cancel(); isReplacing = replace
        if let selectedText, !selectedText.isEmpty { find.stringValue = selectedText }
        if folder == nil { folder = defaultFolder }
        if selectedScope == .workspace && !hasWorkspace { scope.selectedSegment = ProjectSearchScope.all.rawValue }
        replaceRow.isHidden = !replace
        replaceButton.isHidden = !replace
        replaceOneButton.isHidden = !replace
        refreshLocalization()
        if !window.isVisible, let parent {
            parent.addChildWindow(window, ordered: .above)
            let visible = parent.screen?.visibleFrame ?? parent.frame
            window.setContentSize(.init(width: min(980, visible.width - 32), height: min(600, visible.height - 80)))
            window.setFrameTopLeftPoint(.init(x: max(visible.minX, min(parent.frame.midX - window.frame.width / 2, visible.maxX - window.frame.width)),
                                             y: min(visible.maxY, max(visible.minY + window.frame.height, parent.frame.maxY - 70))))
        }
        window.appearance = parent?.effectiveAppearance
        window.contentView?.layoutSubtreeIfNeeded()
        split.adjustSubviews()
        dismissal.start(window: window) { [weak self] in self?.dismiss(restoreFocus: false) }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(find)
        invalidateAndSearch()
    }

    func dismiss(restoreFocus: Bool = true) {
        dismissal.stop()
        cancel()
        guard let window else { return }
        let parent = window.parent; parent?.removeChildWindow(window); window.orderOut(nil)
        if restoreFocus { parent?.makeKeyAndOrderFront(nil) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        window?.title = catalog.text(isReplacing ? "Replace in Files" : "Find in Files")
        find.placeholderString = catalog.text("Find"); find.setAccessibilityLabel(catalog.text("Find"))
        replacement.placeholderString = catalog.text("Replace with"); replacement.setAccessibilityLabel(catalog.text("Replace with"))
        let selection = max(0, scope.selectedSegment), selectedMode = max(0, mode.indexOfSelectedItem)
        for (index, key) in ["All", "Open Documents", "Workspace", "Folder"].enumerated() { scope.setLabel(catalog.text(key), forSegment: index) }
        scope.selectedSegment = selection
        mode.removeAllItems(); mode.addItems(withTitles: ["Normal", "Extended", "Regex"].map { catalog.text($0) }); mode.selectItem(at: selectedMode)
        for item in mode.itemArray { item.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil) }
        mode.imagePosition = .imageOnly
        mode.toolTip = catalog.text("Search mode")
        scope.setAccessibilityLabel(catalog.text("Scope")); mode.setAccessibilityLabel(catalog.text("Search mode"))
        for (button, key) in [(matchCase, "Match case"), (wholeWord, "Whole word"), (dotNewline, ". matches newline")] {
            button.toolTip = catalog.text(key); button.setAccessibilityLabel(catalog.text(key))
        }
        heading.stringValue = catalog.text(isReplacing ? "Replace in Files" : "Find in Files")
        closeButton.toolTip = catalog.text("Close"); closeButton.setAccessibilityLabel(catalog.text("Close"))
        openButton.title = catalog.text("Open in Find Window")
        replaceOneButton.title = catalog.text("Replace")
        maskEnabled.title = catalog.text("File mask:")
        mask.setAccessibilityLabel(catalog.text("File mask:"))
        mask.toolTip = catalog.text("Filename patterns separated by commas; * and ? are wildcards. Prefix ! to exclude.")
        clearFind.toolTip = catalog.text("Clear"); clearFind.setAccessibilityLabel(catalog.text("Clear"))
        regex.toolTip = catalog.text("Regex"); regex.setAccessibilityLabel(catalog.text("Regex"))
        browse.title = catalog.text("Browse…"); searchButton.toolTip = catalog.text("Find All"); searchButton.setAccessibilityLabel(catalog.text("Find All"))
        replaceButton.title = catalog.text("Replace All"); cancelButton.title = catalog.text("Cancel")
        previewHint.stringValue = catalog.text(isReplacing
            ? "Changes stay unsaved."
            : "Double-click a result to open it. Searches use the same options as Find.")
        previewHint.toolTip = catalog.text("Changes stay unsaved in the editor. Undo is available in each document.")
        if let result { rows = result.rows(catalog: catalog); table.reloadData() }
        if let summary { rows = MultiFileSearchResults.replacementRows(summary, catalog: catalog); table.reloadData() }
        updateStatus(); updateControls(); updatePreview()
    }
    func applyPreferences(_ settings: AppSettings) {
        guard includeHiddenFiles != settings.showHiddenFiles else { return }
        includeHiddenFiles = settings.showHiddenFiles
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .abort) }
        if window?.isVisible == true { invalidateAndSearch() }
        else { cancel(); result = nil; summary = nil; rows = []; table.reloadData(); preview.clear(); updateControls() }
    }
    func currentQuery() -> SearchQuery {
        SearchQuery(pattern: find.stringValue, replacement: replacement.stringValue,
                    options: SearchOptions(mode: SearchMode.allCases[max(0, mode.indexOfSelectedItem)],
                                           matchCase: matchCase.isOn, wholeWord: wholeWord.isOn,
                                           dotMatchesNewline: dotNewline.isOn, scope: .allOpenDocuments, includeHiddenFiles: includeHiddenFiles),
                    fileMask: maskEnabled.state == .on ? mask.stringValue : nil)
    }
    func setQuery(_ query: SearchQuery) {
        find.stringValue = query.pattern; replacement.stringValue = query.replacement
        maskEnabled.state = query.fileMask == nil ? .off : .on; mask.stringValue = query.fileMask ?? ""
        mode.selectItem(at: SearchMode.allCases.firstIndex(of: query.options.mode) ?? 0)
        matchCase.isOn = query.options.matchCase; wholeWord.isOn = query.options.wholeWord
        dotNewline.isOn = query.options.dotMatchesNewline
        invalidateAndSearch()
    }
    func configureWorkspace(_ roots: [WorkspaceRoot]) {
        hasWorkspace = !roots.isEmpty; workspaceCount = roots.count; workspacePaths = roots.map(\.canonicalPath)
        if !hasWorkspace && selectedScope == .workspace { scope.selectedSegment = ProjectSearchScope.all.rawValue }
        updateControls()
    }
    func selectScope(_ value: ProjectSearchScope) {
        guard value != .workspace || hasWorkspace else { return }
        scope.selectedSegment = value.rawValue; invalidateAndSearch()
    }
    func selectFolder(_ url: URL?) { folder = url; scope.selectedSegment = (url == nil ? ProjectSearchScope.all : .folder).rawValue; invalidateAndSearch() }

    private func updateControls() {
        let folderScope = selectedScope == .folder
        directory.stringValue = folderScope ? (folder?.path ?? catalog.text("Choose a folder…"))
            : selectedScope == .workspace || selectedScope == .all ? catalog.text("Workspace folders: %1$@", arguments: [String(workspaceCount)]) : ""
        scope.setEnabled(hasWorkspace && !applying, forSegment: ProjectSearchScope.workspace.rawValue)
        directory.setAccessibilityIdentifier("duckpad.multifile.directory")
        directory.toolTip = folderScope ? folder?.path : selectedScope == .workspace || selectedScope == .all
            ? (workspacePaths.isEmpty ? nil : workspacePaths.joined(separator: "\n")) : nil
        browse.isHidden = !folderScope
        dotNewline.isEnabled = mode.indexOfSelectedItem == 2 && !applying
        dotNewline.isHidden = mode.indexOfSelectedItem != 2
        regex.isOn = mode.indexOfSelectedItem == 2
        mask.isEnabled = maskEnabled.state == .on && !applying
        clearFind.isHidden = find.stringValue.isEmpty
        for control in [find as NSControl, replacement, scope, mode, matchCase, wholeWord, regex, maskEnabled] { control.isEnabled = !applying }
        searchButton.isEnabled = !running && !find.stringValue.isEmpty
        replaceButton.isEnabled = !running && result.map { $0.matchCount > 0 && !$0.isTruncated } == true
        openButton.isEnabled = !running && result != nil
        replaceOneButton.isEnabled = replaceButton.isEnabled && rows.indices.contains(table.selectedRow) && rows[table.selectedRow].snippet != nil
        openButton.isPrimary = !isReplacing
        cancelButton.isHidden = !running
        empty.isHidden = !rows.isEmpty
        empty.stringValue = catalog.text(running ? "Searching…" : find.stringValue.isEmpty ? "Type to search in files" : "No matches")
    }
    private func setStatus(_ key: String, _ args: [CVarArg] = []) { statusKey = key; statusArguments = args; updateStatus() }
    private func updateStatus() {
        status.stringValue = catalog.text(statusKey, arguments: statusArguments)
        resultCount.stringValue = status.stringValue
        resultCount.toolTip = status.stringValue
    }
    private func invalidateAndSearch() {
        cancel(); result = nil; summary = nil; rows = []; table.reloadData(); preview.clear()
        setStatus("Type to search in files"); updateControls()
        guard !find.stringValue.isEmpty else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.searchPressed()
        }
    }
    @objc func searchPressed() {
        guard !applying, !find.stringValue.isEmpty else { return }
        cancel(); result = nil; summary = nil; rows = []; table.reloadData(); preview.clear()
        let token = generation, query = currentQuery(), selectedScope = selectedScope, root = selectedScope == .folder ? folder : nil
        if selectedScope == .folder && root == nil { setStatus("Choose a folder…"); return }
        running = true; setStatus("Searching…"); updateControls()
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.running = false; self.updateControls() } }
            do {
                let result: MultiFileSearchResults?
                if let search = self.onSearchRequest {
                    result = try await search(query, selectedScope, root) { [weak self] partial in
                        guard let self, self.generation == token, self.running, !self.applying else { return }
                        self.display(partial)
                        self.setStatus("Searching… %1$@ matches in %2$@ files", [String(partial.matchCount), String(partial.documentCount)])
                        self.updateControls()
                    }
                } else if let search = self.onSearchWithProgress {
                    result = try await search(query, root) { [weak self] partial in
                        guard let self, self.generation == token, self.running, !self.applying else { return }
                        self.display(partial)
                        self.setStatus("Searching… %1$@ matches in %2$@ files", [String(partial.matchCount), String(partial.documentCount)])
                        self.updateControls()
                    }
                } else { result = try await self.onSearch?(query, root) }
                guard let result, !Task.isCancelled, self.generation == token else { return }
                self.display(result)
                if result.matchCount > self.rows.count {
                    self.setStatus("Matches: %1$@ · Files: %2$@ · Skipped: %3$@ · Showing first %4$@ matches",
                        [String(result.matchCount) + (result.isTruncated ? "+" : ""), String(result.documentCount), String(result.skippedCount), String(self.rows.count)])
                } else {
                    self.setStatus(result.isTruncated ? "Matches: %1$@+ · Files: %2$@ · Skipped: %3$@ (results truncated)"
                                   : "Matches: %1$@ · Files: %2$@ · Skipped: %3$@",
                                   [String(result.matchCount), String(result.documentCount), String(result.skippedCount)])
                }
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.setStatus("Search failed: %1$@", [PresentationErrorText.message(error, catalog: self.catalog)])
            }
        }
    }
    private func display(_ value: MultiFileSearchResults) {
        let selection = table.selectedRow
        result = value; rows = value.rows(catalog: catalog); table.reloadData()
        if rows.indices.contains(selection) {
            table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        } else if let first = rows.firstIndex(where: { $0.target != nil }) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            updatePreview()
        }
    }
    @objc func replacePressed() {
        guard replaceButton.isEnabled, let result, let window else { return }
        let token = generation, query = currentQuery()
        let alert = NSAlert()
        alert.messageText = catalog.text("Replace matches in %1$@ files?", arguments: [String(result.documentCount)])
        alert.informativeText = catalog.text("Changes stay unsaved in the editor. Undo is available in each document.")
        alert.addButton(withTitle: catalog.text("Cancel")); alert.addButton(withTitle: catalog.text("Replace All"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self, self.generation == token else { return }
            self.applyReplacement(query, result: result)
        }
    }
    func applyReplacement(_ query: SearchQuery, result: MultiFileSearchResults) {
        guard !running, !result.isTruncated else { return }
        cancel(); let token = generation
        running = true; applying = true; updateControls(); setStatus("Replacing in open documents…")
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.running = false; self.applying = false; self.updateControls() } }
            do {
                guard let summary = try await self.onReplace?(query, result), self.generation == token else { return }
                self.summary = summary; self.result = nil
                self.setStatus(summary.wasCancelled ? "Cancelled · Replacements: %1$@ · Documents: %2$@ · Skipped: %3$@"
                               : "Replacements: %1$@ · Documents: %2$@ · Skipped: %3$@",
                               [String(summary.replacementCount), String(summary.changedDocumentCount), String(summary.skippedDocumentCount)])
                // Old result locations no longer describe the edited buffers.
                self.rows = MultiFileSearchResults.replacementRows(summary, catalog: self.catalog)
                self.table.reloadData(); self.preview.clear()
            } catch {
                guard self.generation == token else { return }
                self.setStatus("Replace All failed: %1$@", [PresentationErrorText.message(error, catalog: self.catalog)])
            }
        }
    }
    func cancel() {
        task?.cancel(); task = nil; generation = UUID(); running = false; applying = false
        previewTask?.cancel(); previewTask = nil; previewGeneration = UUID()
    }
    @objc private func cancelPressed() {
        // Keep the operation identity while a partial replacement returns its summary.
        if applying { task?.cancel(); return }
        cancel(); setStatus("Cancelled"); updateControls()
    }
    @objc private func browsePressed() {
        guard !applying else { return }
        cancel(); let token = generation
        setStatus("Choose a folder…"); updateControls()
        task = Task { [weak self] in
            guard let self else { return }
            let folder = await self.onChooseFolder?()
            guard self.generation == token, !Task.isCancelled else { return }
            guard let folder else { self.setStatus("Cancelled"); self.updateControls(); return }
            self.selectFolder(folder)
        }
    }
    @objc private func regexChanged() { mode.selectItem(at: regex.isOn ? 2 : 0); invalidateAndSearch() }
    @objc private func clearPressed() { find.stringValue = ""; invalidateAndSearch(); window?.makeFirstResponder(find) }
    @objc private func openResultsPressed() {
        guard let result else { return }
        let query = currentQuery(); dismiss(); onOpenResults?(query, result)
    }
    @objc private func replaceOnePressed() {
        guard replaceOneButton.isEnabled, let result, rows.indices.contains(table.selectedRow), let target = rows[table.selectedRow].target else { return }
        let selected: MultiFileSearchResults
        let source: MultiFileSearchResults
        if case .combined(let combined) = result {
            switch target { case .open: source = .open(combined.open); case .folder: source = .folder(combined.folder); case .document: return }
        } else { source = result }
        switch (source, target) {
        case (.open(let source), .open(let match)):
            guard let document = source.documents.first(where: { $0.tabID == match.tabID }) else { return }
            selected = .open(.init(generation: source.generation, documents: [.init(tabID: document.tabID, title: document.title, matches: [match], generatedTitle: document.generatedTitle)], isTruncated: false, searchedByteCount: source.searchedByteCount))
        case (.folder(let source), .folder(let document, let match)):
            selected = .folder(.init(rootPath: source.rootPath, documents: [.init(path: document.path, relativePath: document.relativePath, identity: document.identity, matches: [match])], isTruncated: false, searchedFileCount: 1, skippedFileCount: 0, searchedByteCount: source.searchedByteCount))
        default: return
        }
        applyReplacement(currentQuery(), result: selected)
    }
    @objc private func closePressed() { dismiss() }
    @objc private func optionsChanged() { invalidateAndSearch() }
    func controlTextDidChange(_ obj: Notification) { invalidateAndSearch() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows.indices.contains(row) && rows[row].target != nil }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { CommandPaletteRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("multifile-row")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? SearchResultLineCell ?? SearchResultLineCell()
        cell.identifier = id
        cell.apply(title: rows[row].title, detail: rows[row].detail, query: currentQuery())
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updatePreview() }
    private func updatePreview() {
        previewTask?.cancel(); previewGeneration = UUID()
        updateControls()
        guard rows.indices.contains(table.selectedRow), let snippet = rows[table.selectedRow].snippet,
              let target = rows[table.selectedRow].target else {
            previewTitle.stringValue = catalog.text("Match Preview"); preview.clear(); return
        }
        let row = rows[table.selectedRow]
        previewTitle.stringValue = row.detail
        let line: Int
        switch target { case .open(let match): line = match.line; case .folder(_, let match): line = match.line; case .document: return }
        let source = snippet as NSString
        let found = currentQuery().options.mode == .normal ? source.range(of: find.stringValue, options: matchCase.isOn ? [] : .caseInsensitive) : NSRange(location: NSNotFound, length: 0)
        let start = found.location == NSNotFound ? 0 : source.substring(to: found.location).utf8.count
        let length = found.location == NSNotFound ? 0 : source.substring(with: found).utf8.count
        preview.apply(.init(text: snippet, firstLine: line, matchLine: line, highlight: .init(location: start, length: length)))
        let token = previewGeneration
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self, let content = await self.onPreview?(target),
                  !Task.isCancelled, self.previewGeneration == token else { return }
            self.preview.apply(content)
        }
    }
    @objc func activateSelection() {
        guard rows.indices.contains(table.selectedRow), let target = rows[table.selectedRow].target else { return }
        dismiss(); onActivate?(target)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)) where control === find && isReplacing:
            window?.makeFirstResponder(replacement)
        case #selector(NSResponder.insertBacktab(_:)) where control === replacement:
            window?.makeFirstResponder(find)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        case #selector(NSResponder.insertNewline(_:)): searchPressed()
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            var row = table.selectedRow + delta
            while rows.indices.contains(row) && rows[row].target == nil { row += delta }
            if rows.indices.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        default: return false
        }
        return true
    }
}
