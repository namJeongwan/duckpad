import AppKit
import DuckpadApplication
import DuckpadDomain

public struct DuckpadSettingsSmokeState: Equatable, Sendable {
    public let appearanceMode: AppAppearanceMode
    public let defaultWordWrapEnabled: Bool
    public let defaultWrapMarkerVisible: Bool
    public let wrapMarkerControlEnabled: Bool
    public let status: String

    public init(
        appearanceMode: AppAppearanceMode,
        defaultWordWrapEnabled: Bool,
        defaultWrapMarkerVisible: Bool,
        wrapMarkerControlEnabled: Bool,
        status: String
    ) {
        self.appearanceMode = appearanceMode
        self.defaultWordWrapEnabled = defaultWordWrapEnabled
        self.defaultWrapMarkerVisible = defaultWrapMarkerVisible
        self.wrapMarkerControlEnabled = wrapMarkerControlEnabled
        self.status = status
    }
}

@MainActor
public final class DuckpadSettingsWindowController: NSWindowController, NSWindowDelegate {
    public static let categories = ["General", "Tab Bar", "Editing", "Dark Mode", "Margins/Border/Edge", "New Document", "Default Directory", "Recent Files History", "Indentation", "Searching"]
    public private(set) var selectedCategory = "General"
    private var pages: [String: NSView] = [:]
    private var categoryButtons: [NSButton] = []
    private var booleanControls: [(NSButton, WritableKeyPath<AppSettings, Bool>)] = []
    private var numberControls: [(NSPopUpButton, WritableKeyPath<AppSettings, Int>)] = []
    let editorFont = NSPopUpButton(frame: .zero, pullsDown: false)
    private let appearance = NSPopUpButton(frame: .zero, pullsDown: false)
    private let wordWrap = NSButton(checkboxWithTitle: "Wrap long lines in new tabs", target: nil, action: nil)
    private let wrapMarkers = NSButton(checkboxWithTitle: "Show wrap symbols in new tabs", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var settings = AppSettings.defaults
    private var update: ((AppSettings) async -> AppSettingsUpdateOutcome)?
    private var updateTask: Task<Void, Never>?
    public var acceptsUpdates: (() -> Bool)?
    public var onUpdateTaskStarted: ((Task<Void, Never>) -> Void)?
    public var isUpdating: Bool { updateTask != nil }

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func present(
        settings: AppSettings,
        update: @escaping (AppSettings) async -> AppSettingsUpdateOutcome
    ) {
        configure(settings: settings, update: update)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func configure(
        settings: AppSettings,
        update: @escaping (AppSettings) async -> AppSettingsUpdateOutcome
    ) {
        self.update = update
        if !isUpdating { render(settings) }
    }

    public func selectAppearance(_ mode: AppAppearanceMode) {
        var proposed = settings
        proposed.appearanceMode = mode
        startUpdate(proposed)
    }

    public func smokeState() -> DuckpadSettingsSmokeState {
        DuckpadSettingsSmokeState(
            appearanceMode: selectedAppearanceMode,
            defaultWordWrapEnabled: wordWrap.state == .on,
            defaultWrapMarkerVisible: wrapMarkers.state == .on,
            wrapMarkerControlEnabled: wrapMarkers.isEnabled,
            status: status.stringValue
        )
    }

    public func applyForSmoke(_ settings: AppSettings) async {
        await apply(settings)
    }

    public func submitForSmoke(_ settings: AppSettings) {
        startUpdate(settings)
    }

    public func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }

    deinit {
        updateTask?.cancel()
    }

    public func selectCategory(_ category: String) {
        guard Self.categories.contains(category) else { return }
        selectedCategory = category
        for (name, page) in pages { page.isHidden = name != category }
        let categoryHasKeyboardFocus = categoryButtons.contains { window?.firstResponder === $0 }
        for button in categoryButtons { button.state = button.title == category ? .on : .off }
        if categoryHasKeyboardFocus, let selected = categoryButtons.first(where: { $0.title == category }) {
            window?.makeFirstResponder(selected)
        }
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 4
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let pageHost = NSView()
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        for category in Self.categories {
            let button = NSButton(title: category, target: self, action: #selector(categoryChanged(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.alignment = .left
            button.setAccessibilityLabel(category + " preferences")
            sidebar.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
            categoryButtons.append(button)
            let heading = NSTextField(labelWithString: category)
            heading.font = .systemFont(ofSize: 17, weight: .semibold)
            let page = NSStackView(views: [heading])
            page.orientation = .vertical
            page.alignment = .leading
            page.spacing = 14
            page.translatesAutoresizingMaskIntoConstraints = false
            pageHost.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
                page.topAnchor.constraint(equalTo: pageHost.topAnchor),
                page.bottomAnchor.constraint(lessThanOrEqualTo: pageHost.bottomAnchor),
            ])
            pages[category] = page
        }
        func checkbox(_ title: String, _ key: WritableKeyPath<AppSettings, Bool>, _ category: String) {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(settingChanged(_:)))
            button.setAccessibilityLabel(title)
            booleanControls.append((button, key))
            (pages[category] as? NSStackView)?.addArrangedSubview(button)
        }
        func choices(_ title: String, _ key: WritableKeyPath<AppSettings, Int>, _ choices: [(String, Int)], _ category: String) {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            for (label, value) in choices {
                popup.addItem(withTitle: label)
                popup.lastItem?.representedObject = value
            }
            popup.target = self
            popup.action = #selector(settingChanged(_:))
            popup.setAccessibilityLabel(title)
            numberControls.append((popup, key))
            let row = NSStackView(views: [NSTextField(labelWithString: title), popup])
            row.orientation = .horizontal
            row.spacing = 12
            (pages[category] as? NSStackView)?.addArrangedSubview(row)
        }
        checkbox("Follow the current document’s directory", \.fileDialogFollowsDocument, "Default Directory")
        let directoryNote = NSTextField(wrappingLabelWithString: "Open and Save As start beside the active file. When turned off, or for an untitled tab, macOS remembers the last used location.")
        (pages["Default Directory"] as? NSStackView)?.addArrangedSubview(directoryNote)
        directoryNote.widthAnchor.constraint(lessThanOrEqualTo: pageHost.widthAnchor).isActive = true
        choices("Maximum entries", \.recentFileLimit, [("None", 0), ("5", 5), ("10", 10), ("15", 15), ("20", 20), ("30", 30), ("50", 50)], "Recent Files History")
        choices("Display", \.recentFilePathMode, [("File name only", 0), ("Full path", 1), ("Disambiguate duplicates", 2)], "Recent Files History")
        let recentNote = NSTextField(wrappingLabelWithString: "Open Recent shows up to this many entries from macOS recent document history. Changing the limit does not delete that history.")
        (pages["Recent Files History"] as? NSStackView)?.addArrangedSubview(recentNote)
        recentNote.widthAnchor.constraint(lessThanOrEqualTo: pageHost.widthAnchor).isActive = true
        checkbox("Fill Find field with selected text", \.fillFindWithSelection, "Searching")
        choices("Maximum selected characters", \.findSelectionMaximumCharacters,
                [("256", 256), ("512", 512), ("1024", 1024), ("4096", 4096), ("16383", 16383)], "Searching")
        checkbox("Use monospaced font in Find and Replace", \.monospacedFindFields, "Searching")
        let searchNote = NSTextField(wrappingLabelWithString: "An empty or oversized selection keeps the previous search text. The selection and document stay unchanged.")
        (pages["Searching"] as? NSStackView)?.addArrangedSubview(searchNote)
        searchNote.widthAnchor.constraint(lessThanOrEqualTo: pageHost.widthAnchor).isActive = true
        checkbox("Show menu bar in document windows", \.menuBarVisible, "General")
        checkbox("Show status bar", \.statusBarVisible, "General")
        checkbox("Multi-line tabs", \.multilineTabsEnabled, "Tab Bar")
        checkbox("Allow tab drag and drop", \.tabDragEnabled, "Tab Bar")
        checkbox("Show close button", \.showTabCloseButton, "Tab Bar")
        checkbox("Show buttons on inactive tabs", \.showInactiveTabButtons, "Tab Bar")
        for family in NSFontManager.shared.availableFontFamilies.filter({ !$0.hasPrefix(".") }).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13), !font.fontName.hasPrefix(".") else { continue }
            editorFont.addItem(withTitle: family)
            editorFont.lastItem?.representedObject = font.fontName
        }
        editorFont.target = self
        editorFont.action = #selector(settingChanged(_:))
        editorFont.setAccessibilityLabel("Editor font")
        editorFont.setAccessibilityIdentifier("duckpad.settings.editor-font")
        let fontRow = NSStackView(views: [NSTextField(labelWithString: "Font"), editorFont])
        fontRow.spacing = 12
        editorFont.widthAnchor.constraint(equalToConstant: 260).isActive = true
        (pages["Editing"] as? NSStackView)?.addArrangedSubview(fontRow)
        choices("Font size (pt)", \.editorFontSize, (6...72).map { (String($0), $0) }, "Editing")
        checkbox("Automatically reload files changed on disk", \.liveFileReloadEnabled, "General")
        checkbox("Highlight current line", \.highlightCurrentLine, "Editing")
        choices("Caret width", \.caretWidth, [("1", 1), ("2", 2), ("3", 3)], "Editing")
        choices("Caret blink rate", \.caretBlinkPeriod, [("Fast", 250), ("Normal", 500), ("Slow", 1000), ("No blinking", 0)], "Editing")
        choices("Line wrap", \.wrapIndentMode, [("Default", 0), ("Aligned", 1), ("Indent", 2)], "Editing")
        checkbox("Enable scrolling beyond last line", \.scrollBeyondLastLine, "Editing")
        checkbox("Display line number", \.lineNumbersVisible, "Margins/Border/Edge")
        checkbox("Display bookmark", \.bookmarkMarginVisible, "Margins/Border/Edge")
        checkbox("Show vertical edge", \.edgeLineVisible, "Margins/Border/Edge")
        choices("Vertical edge column", \.edgeColumn, [("72", 72), ("80", 80), ("100", 100), ("120", 120)], "Margins/Border/Edge")
        checkbox("Enable virtual space", \.virtualSpaceEnabled, "Editing")
        checkbox("Override language indentation", \.overrideLanguageIndentation, "Indentation")
        choices("Tab size", \.indentationWidth, (1...16).map { (String($0), $0) }, "Indentation")
        checkbox("Use tab characters instead of spaces", \.indentationUsesTabs, "Indentation")
        checkbox("Show indent guide", \.indentationGuidesVisible, "Indentation")
        let indentNote = NSTextField(wrappingLabelWithString: "The override applies to all languages. Turn it off to restore each language’s defaults. Existing text is not converted.")
        (pages["Indentation"] as? NSStackView)?.addArrangedSubview(indentNote)
        indentNote.widthAnchor.constraint(lessThanOrEqualTo: pageHost.widthAnchor).isActive = true

        for mode in AppAppearanceMode.allCases {
            appearance.addItem(withTitle: title(for: mode))
            appearance.lastItem?.representedObject = mode.rawValue
        }
        appearance.target = self
        appearance.action = #selector(settingChanged(_:))
        appearance.setAccessibilityIdentifier("duckpad.settings.appearance")
        appearance.setAccessibilityLabel("Application appearance")
        (pages["Dark Mode"] as? NSStackView)?.addArrangedSubview(appearance)
        for (button, identifier) in [(wordWrap, "default-word-wrap"), (wrapMarkers, "default-wrap-markers")] {
            button.target = self
            button.action = #selector(settingChanged(_:))
            button.setAccessibilityIdentifier("duckpad.settings." + identifier)
            (pages["New Document"] as? NSStackView)?.addArrangedSubview(button)
        }
        let explanation = NSTextField(wrappingLabelWithString: "New tabs use these defaults. Open and restored tabs keep their own line wrap settings.")
        explanation.textColor = .secondaryLabelColor
        (pages["New Document"] as? NSStackView)?.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(lessThanOrEqualTo: pageHost.widthAnchor).isActive = true

        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("duckpad.settings.status")
        status.setAccessibilityLabel("Preferences status")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.lineBreakMode = .byTruncatingTail
        let close = NSButton(title: "Close", target: self, action: #selector(closePreferences(_:)))
        close.keyEquivalent = "\u{1b}"
        close.translatesAutoresizingMaskIntoConstraints = false
        for view in [sidebar, separator, pageHost, status, close] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            sidebar.widthAnchor.constraint(equalToConstant: 170),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            separator.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -12),
            pageHost.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: 20),
            pageHost.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            pageHost.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            pageHost.bottomAnchor.constraint(equalTo: close.topAnchor, constant: -18),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            status.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: close.centerYAnchor),
        ])
        selectCategory(selectedCategory)
    }

    @objc private func categoryChanged(_ sender: NSButton) { selectCategory(sender.title) }
    @objc private func closePreferences(_ sender: Any?) { close() }

    @objc private func settingChanged(_ sender: Any?) {
        var proposed = settings
        if let name = editorFont.selectedItem?.representedObject as? String { proposed.editorFontName = name }
        proposed.appearanceMode = selectedAppearanceMode
        proposed.defaultWordWrapEnabled = wordWrap.state == .on
        proposed.defaultWrapMarkerVisible = wrapMarkers.state == .on
        for (button, key) in booleanControls { proposed[keyPath: key] = button.state == .on }
        for (popup, key) in numberControls {
            if let value = popup.selectedItem?.representedObject as? Int { proposed[keyPath: key] = value }
        }
        startUpdate(proposed)
    }

    private func startUpdate(_ proposed: AppSettings) {
        guard !isUpdating, acceptsUpdates?() ?? true else {
            NSSound.beep()
            return
        }
        setControlsEnabled(false)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.apply(proposed)
            self.setControlsEnabled(true)
            self.updateTask = nil
        }
        updateTask = task
        onUpdateTaskStarted?(task)
    }

    private func apply(_ proposed: AppSettings) async {
        guard let update else { return }
        switch await update(proposed) {
        case .saved(let saved):
            render(saved)
            status.stringValue = "Saved"
        case .savedWithWarning(let saved, let failure):
            render(saved)
            status.stringValue = "Saved, but durability could not be confirmed: \(failure)"
        case .failed(let failure):
            render(settings)
            status.stringValue = "Could not save preferences: \(failure)"
            NSSound.beep()
            showWindow(nil)
        }
    }

    private func render(_ settings: AppSettings) {
        self.settings = settings
        if let item = editorFont.itemArray.first(where: { $0.representedObject as? String == settings.editorFontName }) {
            editorFont.select(item)
        } else {
            editorFont.addItem(withTitle: settings.editorFontName)
            editorFont.lastItem?.representedObject = settings.editorFontName
            editorFont.select(editorFont.lastItem)
        }
        for (button, key) in booleanControls { button.state = settings[keyPath: key] ? .on : .off }
        for (popup, key) in numberControls {
            if let item = popup.itemArray.first(where: { $0.representedObject as? Int == settings[keyPath: key] }) {
                popup.select(item)
            }
        }
        if let index = AppAppearanceMode.allCases.firstIndex(of: settings.appearanceMode) {
            appearance.selectItem(at: index)
        }
        wordWrap.state = settings.defaultWordWrapEnabled ? .on : .off
        wrapMarkers.state = settings.defaultWrapMarkerVisible ? .on : .off
        wrapMarkers.isEnabled = settings.defaultWordWrapEnabled
        status.stringValue = ""
    }

    private func setControlsEnabled(_ enabled: Bool) {
        for (button, _) in booleanControls { button.isEnabled = enabled }
        for (popup, _) in numberControls { popup.isEnabled = enabled }
        editorFont.isEnabled = enabled
        appearance.isEnabled = enabled
        wordWrap.isEnabled = enabled
        wrapMarkers.isEnabled = enabled && wordWrap.state == .on
    }

    private var selectedAppearanceMode: AppAppearanceMode {
        guard let raw = appearance.selectedItem?.representedObject as? String,
              let mode = AppAppearanceMode(rawValue: raw) else { return .system }
        return mode
    }

    private func title(for mode: AppAppearanceMode) -> String {
        switch mode {
        case .system: "Follow macOS"
        case .light: "Light Mode"
        case .dark: "Dark Mode"
        }
    }
}
