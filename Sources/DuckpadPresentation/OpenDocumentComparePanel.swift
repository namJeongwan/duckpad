import DuckpadLocalization
import AppKit

@MainActor
public final class OpenDocumentComparePanel: NSWindowController, NSWindowDelegate {
    public let leftTextView = NSTextView(frame: .zero)
    public let rightTextView = NSTextView(frame: .zero)
    public let leftScrollView = NSScrollView(frame: .zero)
    public let rightScrollView = NSScrollView(frame: .zero)
    public private(set) var leftChangedRangeCount = 0
    public private(set) var rightChangedRangeCount = 0
    public private(set) var leftVisualRowCount = 0
    public private(set) var rightVisualRowCount = 0

    private var comparisonMenu: NSMenu?
    private var previousMenu: NSMenu?
    private var previousWindowsMenu: NSMenu?
    private var comparisonWindowsMenu: NSMenu?
    private var isMirroringScroll = false
    private var completion: (() -> Void)?
    private var lastScrollWasLeft = true
    private var lastNormalizedVerticalPosition: CGFloat = 0
    private var isDismissed = false
    private(set) var dismissTransitionCountForTesting = 0

    public var leftRenderedText: String { leftTextView.string }
    public var rightRenderedText: String { rightTextView.string }
    public var leftNormalizedVerticalPosition: CGFloat { normalizedPosition(of: leftScrollView) }
    public var rightNormalizedVerticalPosition: CGFloat { normalizedPosition(of: rightScrollView) }

    public init(content: OpenDocumentCompareContent, diff: AlignedLineDiff) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = content.title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 320)
        super.init(window: window)
        window.delegate = self
        configure(content: content, diff: diff)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func present(attachedTo parent: NSWindow?) async {
        guard let window, !isDismissed else { return }
        await withCheckedContinuation { continuation in
            completion = { continuation.resume() }
            // A comparison is a separate document window, not a modal sheet.
            window.appearance = parent?.appearance
            if let parent {
                window.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + 36, y: parent.frame.maxY - 36))
            } else { window.center() }
            showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(leftTextView)
        }
    }

    public func dismiss() {
        guard transitionToDismissed(), let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        else {
            window.orderOut(nil)
            finishPresentation()
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        installComparisonMenu()
    }

    public func windowDidResignKey(_ notification: Notification) {
        restorePreviousMenu()
    }

    private func installComparisonMenu() {
        guard NSApplication.shared.mainMenu !== comparisonMenu || comparisonMenu == nil else { return }
        previousMenu = NSApplication.shared.mainMenu
        previousWindowsMenu = NSApplication.shared.windowsMenu
        let menu = NSMenu()
        if let app = previousMenu?.items.first?.copy() as? NSMenuItem {
            menu.addItem(app)
        } else {
            let app = NSMenuItem()
            let submenu = NSMenu(title: "Duckpad")
            submenu.addItem(withTitle: L10n.text("Quit Duckpad"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            app.submenu = submenu
            menu.addItem(app)
        }
        func section(_ title: String) -> NSMenu {
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            root.submenu = submenu
            menu.addItem(root)
            return submenu
        }
        let file = section(L10n.text("File"))
        let close = file.addItem(withTitle: L10n.text("Close Comparison"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.target = window
        let edit = section(L10n.text("Edit"))
        edit.addItem(withTitle: L10n.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let search = section(L10n.text("Search"))
        let find = search.addItem(withTitle: L10n.text("Find…"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        let windows = section(L10n.text("Window"))
        windows.addItem(withTitle: L10n.text("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        comparisonMenu = menu
        comparisonWindowsMenu = windows
        NSApplication.shared.mainMenu = menu
        NSApplication.shared.windowsMenu = windows
    }

    private func restorePreviousMenu() {
        if NSApplication.shared.mainMenu === comparisonMenu { NSApplication.shared.mainMenu = previousMenu }
        if NSApplication.shared.windowsMenu === comparisonWindowsMenu { NSApplication.shared.windowsMenu = previousWindowsMenu }
        comparisonMenu = nil
        comparisonWindowsMenu = nil
        previousMenu = nil
        previousWindowsMenu = nil
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    public func windowDidResize(_ notification: Notification) {
        restoreScrollPositionAfterLayout()
    }

    func layoutForTesting(size: NSSize) {
        window?.setContentSize(size)
        window?.contentView?.layoutSubtreeIfNeeded()
        restoreScrollPositionAfterLayout()
    }

    func setNormalizedVerticalPosition(_ position: CGFloat, fromLeft: Bool) {
        let source = fromLeft ? leftScrollView : rightScrollView
        lastNormalizedVerticalPosition = min(max(position, 0), 1)
        scroll(source, toNormalizedPosition: lastNormalizedVerticalPosition)
        synchronize(from: source)
    }

    func synchronizeScrollForTesting(fromLeft: Bool) {
        synchronize(from: fromLeft ? leftScrollView : rightScrollView)
    }

    private func configure(content: OpenDocumentCompareContent, diff: AlignedLineDiff) {
        guard let window else { return }
        configure(textView: leftTextView, scrollView: leftScrollView, title: content.leftTitle)
        configure(textView: rightTextView, scrollView: rightScrollView, title: content.rightTitle)

        let left = render(side: .left, text: content.leftText, rows: diff.rows)
        let right = render(side: .right, text: content.rightText, rows: diff.rows)
        leftTextView.textStorage?.setAttributedString(left.value)
        rightTextView.textStorage?.setAttributedString(right.value)
        leftChangedRangeCount = left.changedRangeCount
        rightChangedRangeCount = right.changedRangeCount
        leftVisualRowCount = diff.rows.count
        rightVisualRowCount = diff.rows.count

        let panes = NSStackView(views: [
            makePane(title: content.leftTitle, scrollView: leftScrollView),
            makePane(title: content.rightTitle, scrollView: rightScrollView),
        ])
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        panes.spacing = 1
        panes.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(title: L10n.text("Close"), target: self, action: #selector(donePressed))
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.addSubview(panes)
        root.addSubview(done)
        let snapshotNote = NSTextField(labelWithString: L10n.text("Read-only snapshot · Changes to the original documents are not reflected here."))
        snapshotNote.textColor = .secondaryLabelColor
        snapshotNote.font = .systemFont(ofSize: 11)
        snapshotNote.lineBreakMode = .byTruncatingTail
        snapshotNote.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(snapshotNote)
        NSLayoutConstraint.activate([
            snapshotNote.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            snapshotNote.trailingAnchor.constraint(lessThanOrEqualTo: done.leadingAnchor, constant: -12),
            snapshotNote.centerYAnchor.constraint(equalTo: done.centerYAnchor),
            panes.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panes.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panes.topAnchor.constraint(equalTo: root.topAnchor),
            panes.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -10),
            done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            done.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        window.contentView = root
        installScrollObservers()
    }

    private func configure(textView: NSTextView, scrollView: NSScrollView, title: String) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel(L10n.text("%1$@, read-only comparison", L10n.argument(title)))
        textView.setAccessibilityHelp(L10n.text("Changed rows use plus, minus, or tilde markers and semantic highlighting."))

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.setAccessibilityLabel(L10n.text("%1$@ comparison pane", L10n.argument(title)))
    }

    private func makePane(title: String, scrollView: NSScrollView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [label, separator, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        label.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 10).isActive = true
        scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private enum Side { case left, right }

    private func render(
        side: Side,
        text: String,
        rows: [AlignedLineDiff.Row]
    ) -> (value: NSAttributedString, changedRangeCount: Int) {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byClipping
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
        var pendingChangedRange: (range: NSRange, color: NSColor)?
        var changedRanges: [(range: NSRange, color: NSColor)] = []
        for row in rows {
            let reference = side == .left ? row.left : row.right
            let marker = marker(for: row.kind, side: side, hasLine: reference != nil)
            let number = reference.map { String(format: "%5d", $0.number) } ?? "     "
            let line = reference.map { substring(text, utf8Range: $0.utf8Range) } ?? ""
            let start = result.length
            result.append(NSAttributedString(string: "\(marker) \(number)  \(line)\n", attributes: base))
            let range = NSRange(location: start, length: result.length - start)
            if let color = highlightColor(for: row.kind, side: side, hasLine: reference != nil) {
                if let pending = pendingChangedRange,
                   pending.color == color,
                   NSMaxRange(pending.range) == range.location {
                    pendingChangedRange = (
                        NSRange(location: pending.range.location, length: pending.range.length + range.length),
                        color
                    )
                } else {
                    if let pendingChangedRange { changedRanges.append(pendingChangedRange) }
                    pendingChangedRange = (range, color)
                }
            } else {
                if let pendingChangedRange { changedRanges.append(pendingChangedRange) }
                pendingChangedRange = nil
            }
        }
        if let pendingChangedRange { changedRanges.append(pendingChangedRange) }
        for changed in changedRanges {
            result.addAttribute(
                .backgroundColor,
                value: changed.color.withAlphaComponent(0.13),
                range: changed.range
            )
        }
        return (NSAttributedString(attributedString: result), changedRanges.count)
    }

    private func marker(for kind: AlignedLineDiff.Kind, side: Side, hasLine: Bool) -> String {
        guard hasLine else { return " " }
        switch kind {
        case .unchanged: return " "
        case .inserted: return side == .right ? "+" : " "
        case .deleted: return side == .left ? "-" : " "
        case .replaced: return "~"
        }
    }

    private func highlightColor(
        for kind: AlignedLineDiff.Kind,
        side: Side,
        hasLine: Bool
    ) -> NSColor? {
        guard hasLine else { return nil }
        switch kind {
        case .unchanged: return nil
        case .inserted: return side == .right ? .systemGreen : nil
        case .deleted: return side == .left ? .systemRed : nil
        case .replaced: return .systemOrange
        }
    }

    private func substring(_ text: String, utf8Range: Range<Int>) -> String {
        guard let lowerUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Range.lowerBound, limitedBy: text.utf8.endIndex),
              let upperUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Range.upperBound, limitedBy: text.utf8.endIndex),
              let lower = String.Index(lowerUTF8, within: text),
              let upper = String.Index(upperUTF8, within: text) else { return "" }
        return String(text[lower..<upper])
    }

    private func installScrollObservers() {
        for scrollView in [leftScrollView, rightScrollView] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }
    }

    @objc private func scrollBoundsDidChange(_ notification: Notification) {
        if notification.object as AnyObject? === leftScrollView.contentView {
            synchronize(from: leftScrollView)
        } else if notification.object as AnyObject? === rightScrollView.contentView {
            synchronize(from: rightScrollView)
        }
    }

    private func synchronize(from source: NSScrollView) {
        guard !isMirroringScroll else { return }
        isMirroringScroll = true
        defer { isMirroringScroll = false }
        lastScrollWasLeft = source === leftScrollView
        let destination = lastScrollWasLeft ? rightScrollView : leftScrollView
        lastNormalizedVerticalPosition = normalizedPosition(of: source)
        scroll(destination, toNormalizedPosition: lastNormalizedVerticalPosition)
    }

    private func normalizedPosition(of scrollView: NSScrollView) -> CGFloat {
        let maximum = maximumVerticalOffset(of: scrollView)
        guard maximum > 0 else { return 0 }
        return min(max(scrollView.contentView.bounds.origin.y / maximum, 0), 1)
    }

    private func scroll(_ scrollView: NSScrollView, toNormalizedPosition position: CGFloat) {
        let x = scrollView.contentView.bounds.origin.x
        let y = maximumVerticalOffset(of: scrollView) * min(max(position, 0), 1)
        scrollView.contentView.scroll(to: NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func maximumVerticalOffset(of scrollView: NSScrollView) -> CGFloat {
        guard let documentView = scrollView.documentView else { return 0 }
        return max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
    }

    private func restoreScrollPositionAfterLayout() {
        let source = lastScrollWasLeft ? leftScrollView : rightScrollView
        isMirroringScroll = true
        scroll(source, toNormalizedPosition: lastNormalizedVerticalPosition)
        scroll(
            lastScrollWasLeft ? rightScrollView : leftScrollView,
            toNormalizedPosition: lastNormalizedVerticalPosition
        )
        isMirroringScroll = false
    }

    @objc private func donePressed() { dismiss() }

    private func finishPresentation() {
        _ = transitionToDismissed()
        let completion = completion
        self.completion = nil
        completion?()
    }

    private func transitionToDismissed() -> Bool {
        guard !isDismissed else { return false }
        isDismissed = true
        restorePreviousMenu()
        dismissTransitionCountForTesting += 1
        NotificationCenter.default.removeObserver(self)
        return true
    }
}
