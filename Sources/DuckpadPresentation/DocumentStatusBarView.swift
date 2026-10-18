import DuckpadLocalization
import AppKit
import DuckpadApplication

/// Terminal and language controls on the left, document information on the right.
@MainActor
final class DocumentStatusBarView: NSView {
    let terminalButton = StatusBarButton(title: "", target: nil, action: nil)
    let lengthLabel = NSTextField(labelWithString: L10n.text("Length: 0   Lines: 1"))
    let positionButton = StatusBarButton(title: L10n.text("Ln: 1   Col: 1   Sel: 0 | 0"), target: nil, action: nil)
    let lineEndingButton = StatusBarButton(title: "Unix (LF)", target: nil, action: nil)
    let modeButton = StatusBarButton(title: "INS", target: nil, action: nil)
    let overflowButton = StatusBarButton(title: "", target: nil, action: nil)
    private var fullPosition = L10n.text("Ln: 1   Col: 1   Sel: 0 | 0")
    private var compactPosition = L10n.catalog.text("Ln: %1$@   Col: %2$@", arguments: ["1", "1"])
    private var fields: [NSView] = []
    private var statistics: EditorStatusSnapshot?
    private var binarySummary: String?
    private var loadingProgress: FileLoadingProgress?
    private var terminalVisible = false
    private var catalog = L10n.catalog

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityIdentifier("duckpad.status.bar")
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text("Document status"))
        terminalButton.isBordered = false
        terminalButton.imagePosition = .imageOnly
        terminalButton.imageScaling = .scaleProportionallyDown
        terminalButton.setAccessibilityIdentifier("duckpad.status.terminal")
        addSubview(terminalButton)
        overflowButton.isBordered = false
        overflowButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        overflowButton.imagePosition = .imageOnly
        overflowButton.target = self
        overflowButton.action = #selector(showOverflow)
        overflowButton.isHidden = true
        overflowButton.setAccessibilityIdentifier("duckpad.status.more")
        overflowButton.setAccessibilityLabel(catalog.text("More document information"))
        overflowButton.toolTip = catalog.text("More document information")
        addSubview(overflowButton)
        setTerminalVisible(false)
        lengthLabel.lineBreakMode = .byTruncatingTail
        lengthLabel.setAccessibilityIdentifier("duckpad.status.length")
        positionButton.setAccessibilityIdentifier("duckpad.status.position")
        lineEndingButton.setAccessibilityIdentifier("duckpad.status.line-ending")
        modeButton.setAccessibilityIdentifier("duckpad.status.insert-mode")
    }

    required init?(coder: NSCoder) { nil }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        setTerminalVisible(terminalVisible)
        overflowButton.setAccessibilityLabel(catalog.text("More document information"))
        overflowButton.toolTip = catalog.text("More document information")
        setAccessibilityLabel(catalog.text("Document status"))
        positionButton.toolTip = catalog.text("Go to line and column")
        modeButton.toolTip = catalog.text("Toggle insert / overwrite mode")
        if let statistics {
            self.statistics = nil
            apply(statistics, binarySummary: binarySummary, catalog: catalog)
        } else {
            renderLength(catalog: catalog)
            fullPosition = catalog.text("Ln: 1   Col: 1   Sel: 0 | 0")
            compactPosition = catalog.text("Ln: %1$@   Col: %2$@", arguments: ["1", "1"])
            positionButton.title = fullPosition
        }
        needsLayout = true
    }

    func setTerminalVisible(_ visible: Bool) {
        terminalVisible = visible
        let label = catalog.text(visible ? "Hide Terminal" : "Show Terminal")
        terminalButton.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: label)
        terminalButton.setAccessibilityLabel(label)
        terminalButton.toolTip = label + " (⌃`)"
        terminalButton.state = visible ? .on : .off
        terminalButton.contentTintColor = visible ? .controlAccentColor : .secondaryLabelColor
    }

    func install(language: NSButton, encoding: NSButton) {
        fields = [language, lengthLabel, positionButton, lineEndingButton, encoding, modeButton]
        for field in fields {
            field.translatesAutoresizingMaskIntoConstraints = true
            if let control = field as? NSControl {
                control.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            }
            if let button = field as? NSButton {
                button.isBordered = false
                button.image = nil
                button.imagePosition = .noImage
                button.alignment = .left
                button.lineBreakMode = .byTruncatingTail
            }
            addSubview(field)
        }
        positionButton.toolTip = L10n.text("Go to line and column")
        modeButton.toolTip = L10n.text("Toggle insert / overwrite mode")
        needsLayout = true
    }

    func apply(_ status: EditorStatusSnapshot, binarySummary: String? = nil, catalog: LocalizationCatalog = L10n.catalog) {
        guard statistics != status || self.binarySummary != binarySummary else { return }
        self.catalog = catalog
        statistics = status
        self.binarySummary = binarySummary
        renderLength(catalog: catalog)
        fullPosition = catalog.text("Ln: %1$@   Col: %2$@   Sel: %3$@ | %4$@", arguments: [status.line, status.column, status.selectedCharacters, status.selectedLines].map { $0.formatted(.number.locale(catalog.locale)) })
        modeButton.title = binarySummary == nil ? (status.isOvertype ? "OVR" : "INS") : "—"
        compactPosition = catalog.text("Ln: %1$@   Col: %2$@", arguments: [status.line, status.column].map { $0.formatted(.number.locale(catalog.locale)) })
        positionButton.title = fullPosition
        positionButton.setAccessibilityValue(fullPosition)
        positionButton.toolTip = fullPosition + "\n" + catalog.text("Go to line and column")
        needsLayout = true
        modeButton.setAccessibilityValue(modeButton.title)
    }

    func showLoading(_ progress: FileLoadingProgress?) {
        guard progress != loadingProgress else { return }
        loadingProgress = progress
        renderLength()
    }

    private func renderLength(catalog: LocalizationCatalog = L10n.catalog) {
        let loadingSummary = loadingProgress.map {
            catalog.text("Loading: %1$@%%", arguments: [$0.percent.formatted(.number.locale(catalog.locale))])
        }
        lengthLabel.stringValue = loadingSummary ?? binarySummary ?? statistics.map {
            catalog.text("Length: %1$@   Lines: %2$@", arguments: [$0.length, $0.lines].map { $0.formatted(.number.locale(catalog.locale)) })
        } ?? catalog.text("Length: 0   Lines: 1")
        lengthLabel.toolTip = loadingProgress?.path ?? lengthLabel.stringValue
        lengthLabel.setAccessibilityValue(lengthLabel.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        terminalButton.frame = NSRect(x: 4, y: (bounds.height - 20) / 2,
                                      width: min(28, max(0, bounds.width - 8)), height: 20)
        // Keep the language picker beside the terminal, independent of the
        // right-aligned information group's width.
        let languageX = min(40, max(0, bounds.width - 4))
        let languageWidth = min(100, max(0, bounds.width - languageX - 4))
        fields.first?.frame = NSRect(x: languageX, y: (bounds.height - 18) / 2,
                                    width: languageWidth, height: 18)
        guard fields.count == 6 else { return }
        let right = Array(fields.dropFirst())
        let available = max(0, bounds.width - 4 - languageX - languageWidth - 8)
        positionButton.title = fullPosition
        func width(_ view: NSView, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
            min(maximum, max(minimum, view.fittingSize.width + 16))
        }
        var widths = [width(lengthLabel, minimum: 160, maximum: 240),
                      width(positionButton, minimum: 220, maximum: 340),
                      width(lineEndingButton, minimum: 100, maximum: 150),
                      width(right[3], minimum: 70, maximum: 140), 56]
        var visible = Set(right.indices)
        let compact = widths.reduce(0, +) > available
        if compact {
            positionButton.title = compactPosition
            widths[1] = width(positionButton, minimum: 120, maximum: 220)
            // Keep cursor position and encoding readable; secondary controls
            // move to a menu instead of all fields being squeezed into ellipses.
            for index in [0, 4, 2, 3] where visible.reduce(CGFloat(32), { $0 + widths[$1] }) > available {
                visible.remove(index)
            }
        }
        overflowButton.isHidden = !compact
        let overflowWidth: CGFloat = compact ? 32 : 0
        overflowButton.frame = NSRect(x: max(0, bounds.width - 32), y: (bounds.height - 20) / 2, width: 28, height: 20)
        let total = visible.reduce(CGFloat(0)) { $0 + widths[$1] }
        var x = max(languageX + languageWidth + 8, bounds.width - 4 - overflowWidth - total)
        for (index, field) in right.enumerated() {
            field.isHidden = !visible.contains(index)
            guard !field.isHidden else { field.frame = .zero; continue }
            let fieldWidth = min(widths[index], max(0, bounds.width - 4 - overflowWidth - x))
            field.frame = NSRect(x: x + 5, y: (bounds.height - 18) / 2, width: max(0, fieldWidth - 10), height: 18)
            x += fieldWidth
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        WorkspaceColors.chrome.setFill()
        bounds.fill()
        WorkspaceColors.border.setFill()
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        NSRect(x: 0, y: bounds.maxY - pixel, width: bounds.width, height: pixel).fill()
        for field in fields.dropFirst() where !field.isHidden {
            NSRect(x: field.frame.minX - 5, y: 4, width: pixel, height: max(0, bounds.height - 8)).fill()
        }
    }

    func menuAnchor(for field: NSView) -> NSView { field.isHidden ? overflowButton : field }

    func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for field in fields.dropFirst() where field.isHidden || (field === positionButton && positionButton.title != fullPosition) {
            let title = field === positionButton ? fullPosition
                : (field as? NSButton)?.title ?? (field as? NSTextField)?.stringValue ?? ""
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let button = field as? NSButton {
                item.target = self
                item.action = #selector(activateOverflowField(_:))
                item.representedObject = button
                item.isEnabled = button.isEnabled && button.action != nil
                item.toolTip = button.toolTip
            } else {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showOverflow() {
        overflowMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: overflowButton.bounds.height + 2), in: overflowButton)
    }

    @objc private func activateOverflowField(_ sender: NSMenuItem) {
        guard let button = sender.representedObject as? NSButton, button.isEnabled else { return }
        // Close the overflow menu before a field opens its own native menu.
        DispatchQueue.main.async { [weak button] in button?.performClick(nil) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
