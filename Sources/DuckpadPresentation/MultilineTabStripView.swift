import DuckpadLocalization
import AppKit
import DuckpadApplication
import DuckpadDomain

public enum TabContextAction: Equatable, Sendable {
    case close(TabCloseScope)
    case setPinned(Bool)
    case copyFullPath
    case openContainingFolder
    case moveToEditorGroup(EditorGroupSplitOrientation)
    case cloneToEditorGroup(EditorGroupSplitOrientation)
    case focusOtherEditorGroup
    case closeEditorGroup
    case compareWithOpenDocument
}

@MainActor
private final class AccessibleTabView: NSView {
    var onPress: (() -> Void)?
    var onMiddleClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let pointerIsInside: Bool
        if let window, !isHiddenOrHasHiddenAncestor {
            let localLocation = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            pointerIsInside = bounds.contains(localLocation) && visibleRect.contains(localLocation)
        } else {
            pointerIsInside = false
        }
        var options: NSTrackingArea.Options = [
            .activeAlways,
            .inVisibleRect,
            .mouseEnteredAndExited,
        ]
        if pointerIsInside { options.insert(.assumeInside) }
        let area = NSTrackingArea(
            rect: .zero,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        onHoverChanged?(pointerIsInside)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddleClick?() }
        else { super.otherMouseDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

@MainActor
private final class DuckpadTabItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("DuckpadTabItem")
    private let fileIconImage = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let dirtyIndicator = NSView()
    private let pinButton = TabPinButton(frame: .zero)
    var showCloseButton = true
    var showInactiveButtons = false
    private let closeButton = NSButton(
        image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text("Close")) ?? NSImage(),
        target: nil,
        action: nil
    )
    private let activeIndicator = CALayer()
    private let trailingSeparator = CALayer()
    private let bottomSeparator = CALayer()
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    var onContextAction: ((TabContextAction) -> Void)?
    var validateContextAction: ((TabContextAction) -> Bool)?
    var onHoverChanged: ((TabID, Bool) -> Void)?
    private var configuredTab: TabSnapshot?
    private var configuredIndex: Int?
    private var configuredRow: Int?
    private var ownsTrailingSeparator = false
    private var ownsBottomSeparator = false
    private var isHovered = false
    var configuredTabID: TabID? { configuredTab?.id }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            updateVisualState()
            updateActionVisibility()
        }
    }

    override func loadView() {
        let tabView = AccessibleTabView()
        tabView.onPress = { [weak self] in self?.onActivate?() }
        tabView.onMiddleClick = { [weak self] in self?.onClose?() }
        tabView.menuProvider = { [weak self] in self?.makeContextMenu() }
        tabView.onHoverChanged = { [weak self] hovered in
            guard let self, let tabID = configuredTab?.id else { return }
            onHoverChanged?(tabID, hovered)
        }
        view = tabView
        view.wantsLayer = true
        view.layer?.cornerRadius = 0
        view.layer?.borderWidth = 0
        activeIndicator.name = "duckpad.tab.active-indicator"
        activeIndicator.zPosition = 1
        trailingSeparator.name = "duckpad.tab.separator.trailing"
        bottomSeparator.name = "duckpad.tab.separator.bottom"
        view.layer?.addSublayer(activeIndicator)
        view.layer?.addSublayer(trailingSeparator)
        view.layer?.addSublayer(bottomSeparator)
        titleLabel.lineBreakMode = .byClipping
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = false
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        fileIconImage.imageScaling = .scaleProportionallyUpOrDown
        fileIconImage.setAccessibilityElement(false)
        fileIconImage.translatesAutoresizingMaskIntoConstraints = false
        dirtyIndicator.identifier = NSUserInterfaceItemIdentifier("duckpad.tab.dirty-indicator")
        dirtyIndicator.setAccessibilityElement(false)
        dirtyIndicator.wantsLayer = true
        dirtyIndicator.layer?.cornerRadius = 2.5
        dirtyIndicator.translatesAutoresizingMaskIntoConstraints = false
        pinButton.isBordered = false
        pinButton.imageScaling = .scaleProportionallyDown
        pinButton.target = self
        pinButton.action = #selector(pinPressed)
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 3
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fileIconImage)
        view.addSubview(dirtyIndicator)
        view.addSubview(titleLabel)
        view.addSubview(pinButton)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            fileIconImage.leadingAnchor.constraint(equalTo: dirtyIndicator.trailingAnchor, constant: 2),
            fileIconImage.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            fileIconImage.widthAnchor.constraint(equalToConstant: 17),
            fileIconImage.heightAnchor.constraint(equalToConstant: 17),
            dirtyIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            dirtyIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            dirtyIndicator.widthAnchor.constraint(equalToConstant: 5),
            dirtyIndicator.heightAnchor.constraint(equalToConstant: 5),
            titleLabel.leadingAnchor.constraint(equalTo: fileIconImage.trailingAnchor, constant: 2),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            pinButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 1),
            pinButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 20),
            pinButton.heightAnchor.constraint(equalToConstant: 20),
            closeButton.leadingAnchor.constraint(equalTo: pinButton.trailingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -1),
            closeButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        activeIndicator.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: 2)
        updateSeparatorFrames()
    }

    func configure(
        tab: TabSnapshot,
        index: Int,
        row: Int,
        ownsTrailingSeparator: Bool,
        ownsBottomSeparator: Bool,
        isHovered: Bool
    ) {
        self.isHovered = isHovered
        guard configuredTab != tab || configuredIndex != index || configuredRow != row
                || self.ownsTrailingSeparator != ownsTrailingSeparator
                || self.ownsBottomSeparator != ownsBottomSeparator else {
            updateVisualState()
            updateActionVisibility()
            return
        }
        configuredTab = tab
        configuredIndex = index
        configuredRow = row
        self.ownsTrailingSeparator = ownsTrailingSeparator
        self.ownsBottomSeparator = ownsBottomSeparator
        titleLabel.stringValue = tab.title
        dirtyIndicator.isHidden = !tab.isDirty
        titleLabel.toolTip = tab.fullPath ?? tab.title
        view.toolTip = tab.fullPath ?? tab.title
        updateVisualState()
        updateActionVisibility()

        refreshLocalization()
    }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        guard let tab = configuredTab, let index = configuredIndex, let row = configuredRow else { return }
        func text(_ key: String, _ arguments: CVarArg...) -> String { catalog.text(key, arguments: arguments) }
        let stableID = tab.id.rawValue.uuidString.lowercased()
        let state = [
            tab.isActive ? text("selected") : text("not selected"),
            tab.isDirty ? text("modified") : text("unmodified"),
            tab.isPinned ? text("pinned") : text("not pinned"),
            text("index %1$@", L10n.argument(index + 1)),
            text("row %1$@", L10n.argument(row + 1)),
        ].joined(separator: ", ")
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityIdentifier("duckpad.tab.\(stableID)")
        view.setAccessibilityLabel(text("%1$@ tab", L10n.argument(tab.title)))
        view.setAccessibilityValue(state)
        view.setAccessibilityHelp(text("Activate %1$@ tab", L10n.argument(tab.title)))
        closeButton.setAccessibilityIdentifier("duckpad.tab.close.\(stableID)")
        closeButton.setAccessibilityLabel(text("Close %1$@", L10n.argument(tab.title)))
        closeButton.setAccessibilityValue(tab.isDirty ? text("modified tab") : text("unmodified tab"))
        pinButton.setAccessibilityIdentifier("duckpad.tab.pin.\(stableID)")
        pinButton.setAccessibilityLabel(tab.isPinned ? text("Unpin %1$@", L10n.argument(tab.title)) : text("Pin %1$@", L10n.argument(tab.title)))
        pinButton.setAccessibilityValue(tab.isPinned ? text("pinned") : text("unpinned"))
        pinButton.toolTip = tab.isPinned ? text("Unpin Tab") : text("Pin Tab")
        view.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: text("Close %1$@", L10n.argument(tab.title))) { [weak self] in
                guard let self, self.closeButton.isEnabled else { return false }
                self.onClose?()
                return true
            },
            NSAccessibilityCustomAction(name: tab.isPinned ? text("Unpin %1$@", L10n.argument(tab.title)) : text("Pin %1$@", L10n.argument(tab.title))) { [weak self] in
                self?.pinButton.accessibilityPerformPress() ?? false
            },
        ])
    }

    @objc private func closePressed() {
        onClose?()
    }

    @objc private func pinPressed() {
        guard pinButton.isEnabled, let tab = configuredTab else { return }
        onContextAction?(.setPinned(!tab.isPinned))
    }

    func setInteractionsEnabled(_ enabled: Bool) {
        pinButton.isEnabled = enabled
        closeButton.isEnabled = enabled
    }

    private func updateActionVisibility() {
        closeButton.isHidden = !showCloseButton || !(showInactiveButtons || configuredTab?.isActive == true || isSelected || isHovered)
        pinButton.isHidden = !(showInactiveButtons || configuredTab?.isPinned == true || isHovered)
        if !isHovered { pinButton.resetPointerState() }
    }

    private func updateVisualState() {
        guard isViewLoaded else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { updateResolvedVisualState() }
    }

    private func updateResolvedVisualState() {
        let active = configuredTab?.isActive == true || isSelected
        if let tab = configuredTab {
            let icon = MaterialFileIconTheme.shared.icon(
                for: tab.fullPath ?? tab.title,
                appearance: view.effectiveAppearance
            )
            fileIconImage.image = icon.image
            fileIconImage.identifier = NSUserInterfaceItemIdentifier(
                "duckpad.tab.file-icon.\(icon.name)"
            )
        }
        activeIndicator.backgroundColor = NSColor.controlAccentColor.cgColor
        dirtyIndicator.layer?.backgroundColor = NSColor.systemBlue.cgColor
        titleLabel.textColor = active || isHovered ? .labelColor : .secondaryLabelColor
        let separatorColor: NSColor
        if active {
            view.layer?.backgroundColor = (isHovered
                ? NSColor.controlAccentColor.withAlphaComponent(0.13)
                : NSColor.textBackgroundColor.withAlphaComponent(0.98)).cgColor
            separatorColor = isHovered
                ? NSColor.controlAccentColor.withAlphaComponent(0.48)
                : NSColor.separatorColor.withAlphaComponent(0.52)
        } else if isHovered {
            view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.11).cgColor
            separatorColor = NSColor.controlAccentColor.withAlphaComponent(0.34)
        } else {
            view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.44).cgColor
            separatorColor = NSColor.separatorColor.withAlphaComponent(0.32)
        }
        trailingSeparator.backgroundColor = separatorColor.cgColor
        bottomSeparator.backgroundColor = separatorColor.cgColor
        trailingSeparator.isHidden = !ownsTrailingSeparator
        bottomSeparator.isHidden = !ownsBottomSeparator
        updateSeparatorFrames()
        let isPinned = configuredTab?.isPinned == true
        pinButton.isPinned = isPinned
        closeButton.contentTintColor = isHovered ? .controlAccentColor : .secondaryLabelColor
        closeButton.layer?.backgroundColor = isHovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
        activeIndicator.isHidden = !active
    }

    private func updateSeparatorFrames() {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let thickness = 1 / scale
        trailingSeparator.contentsScale = scale
        bottomSeparator.contentsScale = scale
        trailingSeparator.frame = NSRect(
            x: max(0, view.bounds.maxX - thickness),
            y: 0,
            width: thickness,
            height: view.bounds.height
        )
        bottomSeparator.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: thickness)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if let tabID = configuredTab?.id { onHoverChanged?(tabID, false) }
        configuredTab = nil
        configuredIndex = nil
        configuredRow = nil
        ownsTrailingSeparator = false
        ownsBottomSeparator = false
        isHovered = false
        pinButton.resetPointerState()
        onActivate = nil
        onClose = nil
        onContextAction = nil
        validateContextAction = nil
        onHoverChanged = nil
        updateVisualState()
        updateActionVisibility()
    }

    private func makeContextMenu() -> NSMenu? {
        guard let tab = configuredTab else { return nil }
        let menu = NSMenu(title: tab.title)
        add(L10n.text("Close"), action: #selector(closeCurrent), to: menu)
        add(L10n.text("Close Others"), action: #selector(closeOthers), to: menu)
        add(L10n.text("Close to Left"), action: #selector(closeLeft), to: menu)
        add(L10n.text("Close to Right"), action: #selector(closeRight), to: menu)
        menu.addItem(.separator())
        add(L10n.text("Close All"), action: #selector(closeAll), to: menu)
        add(L10n.text("Close Unchanged"), action: #selector(closeUnchanged), to: menu)
        add(L10n.text("Close Unpinned"), action: #selector(closeUnpinned), to: menu)
        menu.addItem(.separator())
        add(tab.isPinned ? L10n.text("Unpin Tab") : L10n.text("Pin Tab"), action: #selector(togglePinned), to: menu)
        menu.addItem(.separator())
        add(L10n.text("Move to Group Right"), action: #selector(moveToGroupRight), to: menu, contextAction: .moveToEditorGroup(.sideBySide))
        add(L10n.text("Move to Group Down"), action: #selector(moveToGroupDown), to: menu, contextAction: .moveToEditorGroup(.stacked))
        add(L10n.text("Clone to Group Right"), action: #selector(cloneToGroupRight), to: menu, contextAction: .cloneToEditorGroup(.sideBySide))
        add(L10n.text("Clone to Group Down"), action: #selector(cloneToGroupDown), to: menu, contextAction: .cloneToEditorGroup(.stacked))
        add(L10n.text("Focus Other Group"), action: #selector(focusOtherEditorGroup), to: menu, contextAction: .focusOtherEditorGroup)
        add(L10n.text("Close Editor Group"), action: #selector(closeEditorGroup), to: menu, contextAction: .closeEditorGroup)
        menu.addItem(.separator())
        add(
            L10n.text("Compare with Open Document…"),
            action: #selector(compareWithOpenDocument),
            to: menu,
            contextAction: .compareWithOpenDocument
        )
        if tab.fullPath != nil {
            menu.addItem(.separator())
            add(L10n.text("Copy Full Path"), action: #selector(copyFullPath), to: menu)
            add(L10n.text("Open Containing Folder"), action: #selector(openContainingFolder), to: menu)
        }
        return menu
    }

    func contextMenu() -> NSMenu? { makeContextMenu() }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        add(title, action: action, to: menu, contextAction: nil)
    }

    private func add(
        _ title: String,
        action: Selector,
        to menu: NSMenu,
        contextAction: TabContextAction?
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let contextAction { item.isEnabled = validateContextAction?(contextAction) ?? false }
        menu.addItem(item)
    }

    @objc private func closeCurrent() { onContextAction?(.close(.current)) }
    @objc private func closeOthers() { onContextAction?(.close(.others)) }
    @objc private func closeLeft() { onContextAction?(.close(.left)) }
    @objc private func closeRight() { onContextAction?(.close(.right)) }
    @objc private func closeAll() { onContextAction?(.close(.all)) }
    @objc private func closeUnchanged() { onContextAction?(.close(.unchanged)) }
    @objc private func closeUnpinned() { onContextAction?(.close(.unpinned)) }
    @objc private func togglePinned() {
        guard let tab = configuredTab else { return }
        onContextAction?(.setPinned(!tab.isPinned))
    }
    @objc private func copyFullPath() { onContextAction?(.copyFullPath) }
    @objc private func openContainingFolder() { onContextAction?(.openContainingFolder) }
    @objc private func moveToGroupRight() { onContextAction?(.moveToEditorGroup(.sideBySide)) }
    @objc private func moveToGroupDown() { onContextAction?(.moveToEditorGroup(.stacked)) }
    @objc private func cloneToGroupRight() { onContextAction?(.cloneToEditorGroup(.sideBySide)) }
    @objc private func cloneToGroupDown() { onContextAction?(.cloneToEditorGroup(.stacked)) }
    @objc private func focusOtherEditorGroup() { onContextAction?(.focusOtherEditorGroup) }
    @objc private func closeEditorGroup() { onContextAction?(.closeEditorGroup) }
    @objc private func compareWithOpenDocument() { onContextAction?(.compareWithOpenDocument) }
}

@MainActor
final class TabDocumentCollectionView: NSCollectionView {
    private var requiredDocumentSize = NSSize(width: 1, height: 1)
    private let insertionMarker = CALayer()

    func showInsertionMarker(_ rect: NSRect?) {
        guard let rect else { insertionMarker.isHidden = true; return }
        wantsLayer = true
        if insertionMarker.superlayer == nil {
            insertionMarker.name = "duckpad.tab.drop-insertion"
            insertionMarker.zPosition = 100
            insertionMarker.cornerRadius = 1.5
            layer?.addSublayer(insertionMarker)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insertionMarker.frame = rect
        effectiveAppearance.performAsCurrentDrawingAppearance {
            insertionMarker.backgroundColor = NSColor.controlAccentColor.cgColor
        }
        insertionMarker.isHidden = false
        CATransaction.commit()
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        showInsertionMarker(nil)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { showInsertionMarker(nil) }
        return super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        showInsertionMarker(nil)
        super.concludeDragOperation(sender)
    }

    func setRequiredDocumentSize(_ size: NSSize) {
        requiredDocumentSize = size
        if frame.size != size { super.setFrameSize(size) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let size = NSSize(
            width: max(newSize.width, requiredDocumentSize.width),
            height: max(newSize.height, requiredDocumentSize.height)
        )
        if frame.size != size { super.setFrameSize(size) }
    }
}

@MainActor
final class TabOverflowScrollView: NSScrollView {
    var multilineEnabled = true
    var onViewportChanged: (() -> Void)?

    func scrollHorizontally(to x: CGFloat) {
        let maximum = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        contentView.scroll(to: NSPoint(x: multilineEnabled ? 0 : min(max(0, x), maximum), y: 0))
        reflectScrolledClipView(contentView)
    }

    var requiresHorizontalScroller = false {
        didSet { synchronizeHorizontalScroller() }
    }
    private var scrollerSuppressionScheduled = false

    override func layout() {
        super.layout()
        suppressUnwantedScrollers()
    }

    override func scrollWheel(with event: NSEvent) {
        guard !multilineEnabled else { pinContentOrigin(); return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollHorizontally(to: contentView.bounds.minX - delta * (event.hasPreciseScrollingDeltas ? 1 : 12))
    }

    override func reflectScrolledClipView(_ cView: NSClipView) {
        if cView === contentView {
            let maximum = max(0, (documentView?.frame.width ?? 0) - cView.bounds.width)
            let origin = NSPoint(x: multilineEnabled ? 0 : min(max(0, cView.bounds.minX), maximum), y: 0)
            if cView.bounds.origin != origin { cView.scroll(to: origin) }
        }
        super.reflectScrolledClipView(cView)
        suppressScrollerChrome()
        onViewportChanged?()
    }

    func pinContentOrigin() {
        let maximum = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        let origin = NSPoint(x: multilineEnabled ? 0 : min(max(0, contentView.bounds.minX), maximum), y: 0)
        if contentView.bounds.origin != origin {
            contentView.scroll(to: origin)
            super.reflectScrolledClipView(contentView)
        }
        onViewportChanged?()
        if hasVerticalScroller { hasVerticalScroller = false }
        if hasHorizontalScroller { hasHorizontalScroller = false }
        suppressScrollerChrome()
    }

    func forceScrollersOffAfterStyleSettlement() {
        let needsSettlement = !autohidesScrollers || requiresHorizontalScroller
            || hasVerticalScroller || hasHorizontalScroller
        suppressUnwantedScrollers()
        guard needsSettlement else { return }
        guard !scrollerSuppressionScheduled else { return }
        scrollerSuppressionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollerSuppressionScheduled = false
            self.suppressUnwantedScrollers()
            self.pinContentOrigin()
        }
    }

    private func suppressUnwantedScrollers() {
        if !autohidesScrollers { autohidesScrollers = true }
        if requiresHorizontalScroller { requiresHorizontalScroller = false }
        if hasVerticalScroller { hasVerticalScroller = false }
        if hasHorizontalScroller { hasHorizontalScroller = false }
        suppressScrollerChrome()
    }

    private func synchronizeHorizontalScroller() {
        guard hasHorizontalScroller != requiresHorizontalScroller else { return }
        hasHorizontalScroller = requiresHorizontalScroller
    }

    private func suppressScrollerChrome() {
        for scroller in [verticalScroller, horizontalScroller].compactMap({ $0 }) {
            if scroller.alphaValue != 0 { scroller.alphaValue = 0 }
            if !scroller.isHidden { scroller.isHidden = true }
            scroller.setAccessibilityHidden(true)
        }
    }
}

@MainActor
public final class MultilineTabStripView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private static let tabPasteboardType = NSPasteboard.PasteboardType(EditorGroupDragPayload.pasteboardType)
    public struct UpdateMetrics: Equatable {
        public fileprivate(set) var fullReloads = 0
        public fileprivate(set) var itemReloads = 0
        public fileprivate(set) var itemInsertions = 0
        public fileprivate(set) var directItemInspections = 0
        public fileprivate(set) var itemConfigurations = 0
    }
    public var onActivate: ((TabID) -> Void)?
    public var onClose: ((TabID) -> Void)?
    public var onMove: ((TabID, Int) -> Void)?
    public var onContextAction: ((TabID, TabContextAction) -> Void)?
    public var onValidateContextAction: ((TabID, TabContextAction) -> Bool)?
    public var onValidateGroupDrop: ((EditorGroupDragPayload, Int, EditorGroupDropOperation) -> Bool)?
    public var onGroupDrop: ((EditorGroupDragPayload, Int, EditorGroupDropOperation) -> Bool)?
    let hostedCollectionView = TabDocumentCollectionView()
    let hostedScrollView = TabOverflowScrollView()
    let flowLayout = MultilineTabCollectionLayout()
    let documentSwitcher = DocumentSwitcherButton(frame: .zero)
    let navigator = NSStackView()
    let previousTabsButton = StatusBarButton(frame: .zero)
    let nextTabsButton = StatusBarButton(frame: .zero)
    private var navigatorWidth: NSLayoutConstraint!
    private var viewportTrailing: NSLayoutConstraint!
    private var navigatorButtonWidths: [NSLayoutConstraint] = []
    private var needsRevealActiveTab = true
    private var appPreferences = AppSettings.defaults
    private var tabs: [TabSnapshot] = []
    private var heightConstraint: NSLayoutConstraint!
    private var measuredContentWidth: CGFloat = 1
    private var measuredContentHeight: CGFloat = 34
    private let bottomSeparator = CALayer()
    private var tabIndexByID: [TabID: Int] = [:]
    private var isSynchronizingSelection = false
    private var isApplyingCollectionStructure = false
    private var requiresVisibleItemRefreshAfterCollectionStructure = false
    private var activeIndex: Int? {
        didSet { if activeIndex != oldValue { needsRevealActiveTab = true } }
    }
    private var hoveredTabID: TabID?
    private var hoveredTabIndex: Int?
    public private(set) var editorGroupID: EditorGroupID = .primary
    public private(set) var updateMetrics = UpdateMetrics()
    public private(set) var interactionsEnabled = true

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(bottomSeparator)
        applyAppearance()
        hostedCollectionView.collectionViewLayout = flowLayout
        hostedCollectionView.dataSource = self
        hostedCollectionView.delegate = self
        hostedCollectionView.isSelectable = true
        hostedCollectionView.allowsMultipleSelection = false
        hostedCollectionView.allowsEmptySelection = false
        hostedCollectionView.backgroundColors = [.clear]
        hostedCollectionView.registerForDraggedTypes([Self.tabPasteboardType])
        hostedCollectionView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        hostedCollectionView.setAccessibilityIdentifier("duckpad.tab.collection")
        hostedCollectionView.setAccessibilityLabel(L10n.text("Open document tabs"))
        hostedCollectionView.register(
            DuckpadTabItem.self,
            forItemWithIdentifier: DuckpadTabItem.identifier
        )
        hostedCollectionView.frame = NSRect(x: 0, y: 0, width: 1, height: 27)
        hostedCollectionView.autoresizingMask = []

        hostedScrollView.documentView = hostedCollectionView
        hostedScrollView.drawsBackground = false
        hostedScrollView.autohidesScrollers = true
        hostedScrollView.hasVerticalScroller = false
        hostedScrollView.hasHorizontalScroller = false
        hostedScrollView.scrollerStyle = .overlay
        hostedScrollView.verticalScrollElasticity = .none
        hostedScrollView.horizontalScrollElasticity = .none
        hostedScrollView.scrollerInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 2)
        hostedScrollView.borderType = .noBorder
        hostedScrollView.translatesAutoresizingMaskIntoConstraints = false
        hostedScrollView.setAccessibilityIdentifier("duckpad.tab.overflow")
        hostedScrollView.setAccessibilityLabel(L10n.text("Multiline tab rows"))

        documentSwitcher.onActivate = { [weak self] id in
            guard self?.interactionsEnabled == true else { return }
            self?.onActivate?(id)
        }
        navigator.orientation = .horizontal
        navigator.spacing = 0
        navigator.edgeInsets = NSEdgeInsets(top: 1, left: 2, bottom: 1, right: 2)
        navigator.translatesAutoresizingMaskIntoConstraints = false
        navigator.isHidden = true
        navigator.setAccessibilityIdentifier("duckpad.tab.navigator")
        for (button, symbol, label, action) in [
            (previousTabsButton, "chevron.left", L10n.text("Scroll tabs left"), #selector(scrollTabsLeft(_:))),
            (nextTabsButton, "chevron.right", L10n.text("Scroll tabs right"), #selector(scrollTabsRight(_:)))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
            navigator.addArrangedSubview(button)
            button.imageScaling = .scaleProportionallyDown
            let width = button.widthAnchor.constraint(equalToConstant: 26)
            width.isActive = true
            navigatorButtonWidths.append(width)
            button.heightAnchor.constraint(equalToConstant: 25).isActive = true
        }
        addSubview(hostedScrollView)
        addSubview(navigator)
        navigatorWidth = navigator.widthAnchor.constraint(equalToConstant: 56)
        navigatorWidth.priority = .defaultHigh
        viewportTrailing = hostedScrollView.trailingAnchor.constraint(equalTo: trailingAnchor)
        hostedScrollView.onViewportChanged = { [weak self] in self?.updateNavigator() }
        heightConstraint = heightAnchor.constraint(equalToConstant: 27)
        NSLayoutConstraint.activate([
            heightConstraint,
            hostedScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostedScrollView.topAnchor.constraint(equalTo: topAnchor),
            hostedScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            viewportTrailing,
            navigator.trailingAnchor.constraint(equalTo: trailingAnchor),
            navigator.topAnchor.constraint(equalTo: topAnchor),
            navigator.heightAnchor.constraint(equalToConstant: 27),
            navigatorWidth,
        ])
        flowLayout.onContentSizeChange = { [weak self] size in
            guard let self else { return }
            measuredContentWidth = size.width
            measuredContentHeight = size.height
            // Collection layout must not invalidate its ancestor constraints
            // while AppKit is still solving the window's current layout pass.
            if heightConstraint.constant != size.height { needsUpdateConstraints = true }
        }
        flowLayout.onLayoutRegenerated = { [weak self] in
            guard let self else { return }
            guard !self.isApplyingCollectionStructure else {
                self.requiresVisibleItemRefreshAfterCollectionStructure = true
                return
            }
            self.requiresVisibleItemRefreshAfterCollectionStructure = false
            self.refreshVisibleItems()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func layout() {
        updateNavigatorLayout()
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let thickness = 1 / scale
        bottomSeparator.name = "duckpad.tab.separator.strip-bottom"
        bottomSeparator.contentsScale = scale
        bottomSeparator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: thickness)
        if flowLayout.engine.backingScale != scale {
            var engine = flowLayout.engine
            engine.backingScale = scale
            flowLayout.engine = engine
        }
        // This borderless surface has no scrollers. AppKit can temporarily
        // reserve legacy scroller space while a row shrinks; using contentSize
        // would wrap that row again and keep the window relaying out forever.
        let viewportWidth = max(1, hostedScrollView.bounds.width)
        if flowLayout.viewportWidth != viewportWidth { needsRevealActiveTab = true }
        flowLayout.viewportWidth = viewportWidth
        hostedCollectionView.layoutSubtreeIfNeeded()
        updateDocumentFrame()
        if heightConstraint.constant != measuredContentHeight { needsUpdateConstraints = true }
        refreshVisibleItems()
        pinTabSurfaceOrigin()
    }

    public func apply(tabs: [TabSnapshot]) {
        hoveredTabID = nil
        hoveredTabIndex = nil
        self.tabs = tabs
        rebuildTabIndices()
        activeIndex = tabs.firstIndex(where: \.isActive)
        documentSwitcher.apply(tabs: tabs)
        flowLayout.itemWidths = tabs.map(tabWidth)
        hostedCollectionView.reloadData()
        updateMetrics.fullReloads += 1
        hostedCollectionView.selectionIndexPaths = activeIndex.map {
            Set([IndexPath(item: $0, section: 0)])
        } ?? []
        flowLayout.invalidateLayout()
        hostedCollectionView.layoutSubtreeIfNeeded()
        updateDocumentFrame()
        updateViewportHeight()
        refreshVisibleItems()
        pinTabSurfaceOrigin()
    }

    public func apply(change: WorkspaceChange) {
        if case let .tabInserted(index) = change.kind {
            applyTabInsertion(change, at: index)
            return
        }
        documentSwitcher.apply(change: change)
        switch change.kind {
        case .persistence:
            guard tabs.count == change.snapshot.tabs.count else {
                apply(tabs: change.snapshot.tabs)
                return
            }
            tabs = change.snapshot.tabs
            synchronizeSelection()
            pinTabSurfaceOrigin()
            return
        case .tabUpdated(let index), .bufferEdited(let index):
            guard tabs.count == change.snapshot.tabs.count,
                  tabs.indices.contains(index) else {
                apply(tabs: change.snapshot.tabs)
                return
            }
            let previous = tabs[index]
            tabs[index] = change.snapshot.tabs[index]
            if previous.title != tabs[index].title || previous.isPinned != tabs[index].isPinned {
                flowLayout.updateItemWidth(tabWidth(tabs[index]), at: index)
            }
            hostedCollectionView.reloadItems(at: [IndexPath(item: index, section: 0)])
            updateMetrics.itemReloads += 1
        case .activeTabChanged(let previousIndex, let currentIndex):
            let affected = [previousIndex, currentIndex]
                .compactMap { $0 }
                .reduce(into: [Int]()) { indices, index in
                    if !indices.contains(index) { indices.append(index) }
                }
            guard tabs.count == change.snapshot.tabs.count,
                  !affected.isEmpty,
                  affected.allSatisfy({ tabs.indices.contains($0) }) else {
                apply(tabs: change.snapshot.tabs)
                return
            }
            for index in affected { tabs[index] = change.snapshot.tabs[index] }
            activeIndex = currentIndex
            isSynchronizingSelection = true
            hostedCollectionView.reloadItems(
                at: Set(affected.map { IndexPath(item: $0, section: 0) })
            )
            hostedCollectionView.selectionIndexPaths = [IndexPath(item: currentIndex, section: 0)]
            isSynchronizingSelection = false
            updateMetrics.itemReloads += affected.count
            pinTabSurfaceOrigin()
        case .tabInserted:
            assertionFailure("tab insertions are handled before the document switcher refresh")
        case .tabRemovalPending(let index):
            if tabs.count == change.snapshot.tabs.count + 1, tabs.indices.contains(index) {
                // Shrink the custom layout cache before the collection view
                // observes the smaller data source, avoiding stale attributes
                // for the old final index during AppKit's delete transaction.
                if hoveredTabID == tabs[index].id { hoveredTabID = nil }
                if hoveredTabIndex == index {
                    hoveredTabIndex = nil
                } else if let hoveredTabIndex, hoveredTabIndex > index {
                    self.hoveredTabIndex = hoveredTabIndex - 1
                }
                requiresVisibleItemRefreshAfterCollectionStructure = false
                isApplyingCollectionStructure = true
                flowLayout.itemWidths = change.snapshot.tabs.map(tabWidth)
                tabs = change.snapshot.tabs
                rebuildTabIndices()
                activeIndex = tabs.firstIndex(where: \.isActive)
                hostedCollectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
                isApplyingCollectionStructure = false
                refreshVisibleItemsAfterCollectionStructure()
                updateDocumentFrame()
                updateViewportHeight()
                synchronizeSelection()
                pinTabSurfaceOrigin()
            } else if tabs.map(\.id) == change.snapshot.tabs.map(\.id) {
                tabs = change.snapshot.tabs
                activeIndex = tabs.firstIndex(where: \.isActive)
                synchronizeSelection()
            } else {
                apply(tabs: change.snapshot.tabs)
            }
        case .tabsRemovalPending:
            apply(tabs: change.snapshot.tabs)
        case .tabRemoved, .tabsRemoved:
            guard tabs.map(\.id) == change.snapshot.tabs.map(\.id) else {
                apply(tabs: change.snapshot.tabs)
                return
            }
            tabs = change.snapshot.tabs
            activeIndex = tabs.firstIndex(where: \.isActive)
            synchronizeSelection()
        case .tabsReordered:
            apply(tabs: change.snapshot.tabs)
        case .reset:
            apply(tabs: change.snapshot.tabs)
        }
    }

    @discardableResult
    public func apply(tab: TabSnapshot, at index: Int) -> Bool {
        guard tabs.indices.contains(index),
              tabs[index].id == tab.id,
              tabs[index].isActive == tab.isActive,
              documentSwitcher.apply(tab: tab, at: index) else { return false }
        let previous = tabs[index]
        tabs[index] = tab
        if previous.title != tab.title || previous.isPinned != tab.isPinned {
            flowLayout.updateItemWidth(tabWidth(tab), at: index)
        }
        hostedCollectionView.reloadItems(at: [IndexPath(item: index, section: 0)])
        updateMetrics.itemReloads += 1
        updateMetrics.directItemInspections += 1
        return true
    }

    @discardableResult
    public func applySelection(
        previous: TabSnapshot,
        at previousIndex: Int,
        current: TabSnapshot,
        at currentIndex: Int
    ) -> Bool {
        guard previousIndex != currentIndex,
              tabs.indices.contains(previousIndex),
              tabs.indices.contains(currentIndex),
              tabs[previousIndex].id == previous.id,
              tabs[currentIndex].id == current.id,
              !previous.isActive,
              current.isActive else { return false }
        guard documentSwitcher.apply(tab: previous, at: previousIndex),
              documentSwitcher.apply(tab: current, at: currentIndex) else { return false }
        tabs[previousIndex] = previous
        tabs[currentIndex] = current
        activeIndex = currentIndex
        isSynchronizingSelection = true
        hostedCollectionView.reloadItems(at: [
            IndexPath(item: previousIndex, section: 0),
            IndexPath(item: currentIndex, section: 0),
        ])
        hostedCollectionView.selectionIndexPaths = [IndexPath(item: currentIndex, section: 0)]
        isSynchronizingSelection = false
        updateMetrics.itemReloads += 2
        updateMetrics.directItemInspections += 2
        pinTabSurfaceOrigin()
        return true
    }

    public func applyPreferences(_ settings: AppSettings) {
        guard appPreferences != settings else { return }
        let modeChanged = appPreferences.multilineTabsEnabled != settings.multilineTabsEnabled
        appPreferences = settings
        if modeChanged {
            hostedScrollView.multilineEnabled = settings.multilineTabsEnabled
            updateNavigatorLayout()
            flowLayout.engine.multilineEnabled = settings.multilineTabsEnabled
            hostedScrollView.setAccessibilityLabel(settings.multilineTabsEnabled ? L10n.text("Multiline tab rows") : L10n.text("Scrollable document tabs"))
            needsRevealActiveTab = true
            needsLayout = true
            needsUpdateConstraints = true
        }
        updateNavigator()
        if !settings.tabDragEnabled { hostedCollectionView.showInsertionMarker(nil) }
        refreshVisibleItems()
    }

    public func setInteractionsEnabled(_ isEnabled: Bool) {
        guard interactionsEnabled != isEnabled else { return }
        interactionsEnabled = isEnabled
        if !isEnabled { hostedCollectionView.showInsertionMarker(nil) }
        hostedCollectionView.isSelectable = isEnabled
        documentSwitcher.setInteractionsEnabled(isEnabled)
        updateNavigator()
        for case let item as DuckpadTabItem in hostedCollectionView.visibleItems() {
            item.setInteractionsEnabled(isEnabled)
        }
    }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        hostedCollectionView.setAccessibilityLabel(catalog.text("Open document tabs"))
        hostedScrollView.setAccessibilityLabel(catalog.text(appPreferences.multilineTabsEnabled ? "Multiline tab rows" : "Scrollable document tabs"))
        previousTabsButton.toolTip = catalog.text("Scroll tabs left")
        previousTabsButton.setAccessibilityLabel(catalog.text("Scroll tabs left"))
        nextTabsButton.toolTip = catalog.text("Scroll tabs right")
        nextTabsButton.setAccessibilityLabel(catalog.text("Scroll tabs right"))
        documentSwitcher.refreshLocalization(catalog: catalog)
        for case let item as DuckpadTabItem in hostedCollectionView.visibleItems() {
            item.refreshLocalization(catalog: catalog)
        }
    }

    public func setEditorGroupID(_ groupID: EditorGroupID) {
        editorGroupID = groupID
    }

    public func showDocumentSwitcher() {
        guard interactionsEnabled, !tabs.isEmpty else { return }
        documentSwitcher.documentPanel.apply(tabs: tabs)
        documentSwitcher.documentPanel.present(relativeTo: hostedScrollView)
    }

    func tearDownHostedViews() {
        hostedCollectionView.showInsertionMarker(nil)
        hoveredTabID = nil
        hoveredTabIndex = nil
        tabIndexByID.removeAll(keepingCapacity: false)
        documentSwitcher.documentPanel.dismiss()
        flowLayout.onContentSizeChange = nil
        flowLayout.onLayoutRegenerated = nil
        hostedCollectionView.unregisterDraggedTypes()
        hostedCollectionView.dataSource = nil
        hostedCollectionView.delegate = nil
        hostedScrollView.onViewportChanged = nil
        hostedScrollView.documentView = nil
        hostedCollectionView.collectionViewLayout = nil
        onActivate = nil
        onClose = nil
        onMove = nil
        onContextAction = nil
        onValidateContextAction = nil
        onValidateGroupDrop = nil
        onGroupDrop = nil
        documentSwitcher.onActivate = nil
    }

    public var contentHeight: CGFloat { measuredContentHeight }
    public var viewportHeight: CGFloat { heightConstraint.constant }
    public var rowCount: Int { flowLayout.rowCount }
    public var tabIDs: [TabID] { tabs.map(\.id) }
    public var activeTabID: TabID? { tabs.first(where: \.isActive)?.id }

    public var selectedTabIsVisible: Bool {
        guard let index = tabs.firstIndex(where: \.isActive),
              let attributes = flowLayout.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
              ) else {
            return false
        }
        return hostedScrollView.contentView.bounds.intersects(attributes.frame)
    }

    public func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    public func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        tabs.count
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: DuckpadTabItem.identifier,
            for: indexPath
        )
        guard let tabItem = item as? DuckpadTabItem,
              tabs.indices.contains(indexPath.item) else {
            return item
        }
        let tab = tabs[indexPath.item]
        configure(tabItem, at: indexPath.item)
        tabItem.onActivate = { [weak self] in
            guard self?.interactionsEnabled == true else { return }
            self?.onActivate?(tab.id)
        }
        tabItem.onClose = { [weak self] in
            guard self?.interactionsEnabled == true else { return }
            self?.onClose?(tab.id)
        }
        tabItem.onContextAction = { [weak self] action in
            guard self?.interactionsEnabled == true else { return }
            self?.onContextAction?(tab.id, action)
        }
        tabItem.validateContextAction = { [weak self] action in
            self?.onValidateContextAction?(tab.id, action) ?? false
        }
        tabItem.onHoverChanged = { [weak self] tabID, isHovered in
            self?.updateHoveredTab(isHovered, tabID: tabID)
        }
        return tabItem
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard let item = item as? DuckpadTabItem,
              hoveredTabID == item.configuredTabID else {
            return
        }
        hoveredTabID = nil
        hoveredTabIndex = nil
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard interactionsEnabled, !isSynchronizingSelection else { return }
        guard let index = indexPaths.first?.item, tabs.indices.contains(index) else { return }
        onActivate?(tabs[index].id)
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        guard interactionsEnabled, appPreferences.tabDragEnabled, tabs.indices.contains(indexPath.item) else { return nil }
        let item = NSPasteboardItem()
        let payload = EditorGroupDragPayload(
            tabID: tabs[indexPath.item].id,
            sourceGroup: editorGroupID
        )
        item.setData(payload.encodedData(), forType: Self.tabPasteboardType)
        return item
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard interactionsEnabled,
              let payload = dragPayload(from: draggingInfo.draggingPasteboard) else {
            hostedCollectionView.showInsertionMarker(nil)
            return []
        }
        let insertion = flowLayout.dropInsertion(at: collectionView.convert(draggingInfo.draggingLocation, from: nil))
        proposedDropOperation.pointee = .before
        let index = min(insertion.index, tabs.count)
        proposedDropIndexPath.pointee = NSIndexPath(forItem: index, inSection: 0)
        if payload.sourceGroup == editorGroupID {
            let allowed = tabs.contains(where: { $0.id == payload.tabID })
            hostedCollectionView.showInsertionMarker(allowed ? insertion.marker : nil)
            return allowed ? .move : []
        }
        let operation = EditorGroupDragPayload.dropOperation(
            optionPressed: NSEvent.modifierFlags.contains(.option)
        )
        let allowed = onValidateGroupDrop?(payload, index, operation) == true
        hostedCollectionView.showInsertionMarker(allowed ? insertion.marker : nil)
        return allowed ? (operation == .copy ? .copy : .move) : []
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        acceptDrop(
            from: draggingInfo.draggingPasteboard,
            insertionIndex: indexPath.item,
            optionPressed: NSEvent.modifierFlags.contains(.option)
        )
    }

    func acceptDrop(from pasteboard: NSPasteboard, insertionIndex: Int) -> Bool {
        acceptDrop(from: pasteboard, insertionIndex: insertionIndex, optionPressed: false)
    }

    func acceptDrop(
        from pasteboard: NSPasteboard,
        insertionIndex: Int,
        optionPressed: Bool
    ) -> Bool {
        guard interactionsEnabled,
              let payload = dragPayload(from: pasteboard) else { return false }
        let boundedInsertionIndex = min(max(0, insertionIndex), tabs.count)
        if payload.sourceGroup != editorGroupID {
            let operation = EditorGroupDragPayload.dropOperation(optionPressed: optionPressed)
            guard onValidateGroupDrop?(payload, boundedInsertionIndex, operation) == true else {
                return false
            }
            return onGroupDrop?(payload, boundedInsertionIndex, operation) == true
        }
        guard !tabs.isEmpty,
              let source = tabs.firstIndex(where: { $0.id == payload.tabID }) else { return false }
        guard let destination = TabDropDestination.finalIndex(
            sourceIndex: source,
            insertionIndex: boundedInsertionIndex,
            itemCount: tabs.count
        ) else { return false }
        performDrop(tabID: payload.tabID, to: destination)
        return true
    }

    public func performDrop(tabID: TabID, to index: Int) {
        guard interactionsEnabled,
              tabs.contains(where: { $0.id == tabID }), tabs.indices.contains(index) else { return }
        onMove?(tabID, index)
    }

    public func performMiddleClick(tabID: TabID) {
        guard interactionsEnabled, tabs.contains(where: { $0.id == tabID }) else { return }
        onClose?(tabID)
    }

    public func contextMenu(for tabID: TabID) -> NSMenu? {
        guard interactionsEnabled,
              let index = tabs.firstIndex(where: { $0.id == tabID }),
              let item = hostedCollectionView.item(at: IndexPath(item: index, section: 0)) as? DuckpadTabItem else {
            return nil
        }
        return item.contextMenu()
    }

    private func updateDocumentFrame() {
        let viewportWidth = max(1, hostedScrollView.bounds.width)
        let width = max(viewportWidth, measuredContentWidth)
        let height = max(measuredContentHeight, hostedScrollView.contentSize.height)
        let documentSize = NSSize(width: width, height: height)
        let widthChanged = hostedCollectionView.frame.width != width
        hostedCollectionView.setRequiredDocumentSize(documentSize)
        hostedScrollView.forceScrollersOffAfterStyleSettlement()
        if widthChanged { flowLayout.invalidateLayout() }
        pinTabSurfaceOrigin()
    }

    private func dragPayload(from pasteboard: NSPasteboard) -> EditorGroupDragPayload? {
        guard let data = pasteboard.data(forType: Self.tabPasteboardType) else { return nil }
        return EditorGroupDragPayload(data: data)
    }

    private func updateViewportHeight() {
        if heightConstraint.constant != measuredContentHeight {
            heightConstraint.constant = measuredContentHeight
        }
    }

    public override func updateConstraints() {
        updateViewportHeight()
        super.updateConstraints()
    }

    private func pinTabSurfaceOrigin() {
        hostedScrollView.pinContentOrigin()
        guard !appPreferences.multilineTabsEnabled, needsRevealActiveTab,
              let activeIndex,
              let frame = flowLayout.layoutAttributesForItem(at: IndexPath(item: activeIndex, section: 0))?.frame else { return }
        let viewport = hostedScrollView.contentView.bounds
        var x = viewport.minX
        if frame.width > viewport.width || frame.minX < viewport.minX { x = frame.minX }
        else if frame.maxX > viewport.maxX { x = frame.maxX - viewport.width }
        needsRevealActiveTab = false
        hostedScrollView.scrollHorizontally(to: x)
    }

    @objc private func scrollTabsLeft(_ sender: Any?) { scrollTabs(forward: false) }
    @objc private func scrollTabsRight(_ sender: Any?) { scrollTabs(forward: true) }

    func scrollTabs(forward: Bool) {
        guard interactionsEnabled, !appPreferences.multilineTabsEnabled else { return }
        needsRevealActiveTab = false
        let viewport = hostedScrollView.contentView.bounds
        hostedScrollView.scrollHorizontally(to: viewport.minX + (forward ? 1 : -1) * max(80, viewport.width * 0.75))
    }

    private func updateNavigatorLayout() {
        // Narrow split panes retain a nonnegative document viewport. Below
        // 40 points, wheel scrolling remains available without tiny buttons.
        let visible = !appPreferences.multilineTabsEnabled && bounds.width >= 40
        let width: CGFloat = visible ? min(56, bounds.width / 2) : 56
        if navigator.isHidden == visible { navigator.isHidden = !visible }
        if navigatorWidth.constant != width { navigatorWidth.constant = width }
        let trailing = visible ? -width : 0
        if viewportTrailing.constant != trailing { viewportTrailing.constant = trailing }
        for constraint in navigatorButtonWidths {
            let buttonWidth = (width - 4) / 2
            if constraint.constant != buttonWidth { constraint.constant = buttonWidth }
        }
    }

    private func updateNavigator() {
        let viewport = hostedScrollView.contentView.bounds
        let enabled = interactionsEnabled && !appPreferences.multilineTabsEnabled && !navigator.isHidden
        previousTabsButton.isEnabled = enabled && viewport.minX > 0.5
        nextTabsButton.isEnabled = enabled && viewport.maxX < measuredContentWidth - 0.5
    }

    private func synchronizeSelection() {
        let authoritative = activeIndex.map {
            Set([IndexPath(item: $0, section: 0)])
        } ?? []
        guard hostedCollectionView.selectionIndexPaths != authoritative else { return }
        isSynchronizingSelection = true
        hostedCollectionView.selectionIndexPaths = authoritative
        isSynchronizingSelection = false
    }

    private func applyTabInsertion(_ change: WorkspaceChange, at index: Int) {
        let updatedTabs = change.snapshot.tabs
        let existingIDs = updatedTabs.enumerated().compactMap { entry in
            entry.offset == index ? nil : entry.element.id
        }
        guard updatedTabs.count == tabs.count + 1,
              (0...tabs.count).contains(index),
              !tabs.contains(where: { $0.id == updatedTabs[index].id }),
              tabs.map(\.id) == existingIDs,
              flowLayout.itemWidths.count == tabs.count else {
            apply(tabs: updatedTabs)
            return
        }

        let previouslyActiveID = tabs.first(where: \.isActive)?.id
        if let hoveredTabIndex, hoveredTabIndex >= index {
            self.hoveredTabIndex = hoveredTabIndex + 1
        }
        tabs = updatedTabs
        rebuildTabIndices()
        activeIndex = tabs.firstIndex(where: \.isActive)
        guard flowLayout.insertItemWidth(tabWidth(updatedTabs[index]), at: index) else {
            apply(tabs: updatedTabs)
            return
        }
        documentSwitcher.apply(change: change)

        let previouslyActiveIndex = previouslyActiveID.flatMap { tabIndexByID[$0] }
        let oldActiveNeedsReload = previouslyActiveIndex.map { !tabs[$0].isActive } ?? false

        isApplyingCollectionStructure = true
        isSynchronizingSelection = true
        hostedCollectionView.insertItems(at: [IndexPath(item: index, section: 0)])
        hostedCollectionView.selectionIndexPaths = activeIndex.map {
            Set([IndexPath(item: $0, section: 0)])
        } ?? []
        isSynchronizingSelection = false
        isApplyingCollectionStructure = false
        updateMetrics.itemInsertions += 1

        if oldActiveNeedsReload, let previouslyActiveIndex {
            hostedCollectionView.reloadItems(
                at: [IndexPath(item: previouslyActiveIndex, section: 0)]
            )
            updateMetrics.itemReloads += 1
        }
        hostedCollectionView.layoutSubtreeIfNeeded()
        updateDocumentFrame()
        updateViewportHeight()
        requiresVisibleItemRefreshAfterCollectionStructure = false
        refreshVisibleItems()
        pinTabSurfaceOrigin()
    }

    private func refreshVisibleItems() {
        for case let item as DuckpadTabItem in hostedCollectionView.visibleItems() {
            guard let path = hostedCollectionView.indexPath(for: item),
                  tabs.indices.contains(path.item) else {
                continue
            }
            configure(item, at: path.item)
        }
    }

    private func refreshVisibleItemsAfterCollectionStructure() {
        let generationBeforeSettlement = flowLayout.layoutGeneration
        hostedCollectionView.layoutSubtreeIfNeeded()
        guard requiresVisibleItemRefreshAfterCollectionStructure
                || flowLayout.layoutGeneration == generationBeforeSettlement else {
            return
        }
        requiresVisibleItemRefreshAfterCollectionStructure = false
        refreshVisibleItems()
    }

    private func configure(_ item: DuckpadTabItem, at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        let row = flowLayout.row(forItemAt: index) ?? 0
        item.showCloseButton = appPreferences.showTabCloseButton
        item.showInactiveButtons = appPreferences.showInactiveTabButtons
        item.setInteractionsEnabled(interactionsEnabled)
        item.configure(
            tab: tab,
            index: index,
            row: row,
            ownsTrailingSeparator: flowLayout.row(forItemAt: index + 1) == row,
            ownsBottomSeparator: row < flowLayout.rowCount - 1,
            isHovered: hoveredTabID == tab.id
        )
        updateMetrics.itemConfigurations += 1
    }

    private func refreshItems(at indices: Set<Int>) {
        for index in indices where tabs.indices.contains(index) {
            guard let item = hostedCollectionView.item(
                at: IndexPath(item: index, section: 0)
            ) as? DuckpadTabItem else { continue }
            configure(item, at: index)
        }
    }

    private func updateHoveredTab(_ isHovered: Bool, tabID: TabID) {
        let nextHoveredTabID: TabID?
        let nextIndex: Int?
        if isHovered, let index = tabIndexByID[tabID] {
            nextHoveredTabID = tabID
            nextIndex = index
        } else if hoveredTabID == tabID {
            nextHoveredTabID = nil
            nextIndex = nil
        } else {
            nextHoveredTabID = hoveredTabID
            nextIndex = hoveredTabIndex
        }
        guard hoveredTabID != nextHoveredTabID || hoveredTabIndex != nextIndex else { return }
        let previousIndex = hoveredTabIndex
        hoveredTabID = nextHoveredTabID
        hoveredTabIndex = nextIndex
        refreshItems(at: Set([previousIndex, nextIndex].compactMap { $0 }))
    }

    private func rebuildTabIndices() {
        tabIndexByID = Dictionary(
            uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    private func tabWidth(_ tab: TabSnapshot) -> CGFloat {
        let width = (tab.title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).width
        // Reserve icon, status, pin, and close slots so hover never moves the title.
        return ceil(width) + 73
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
        refreshVisibleItems()
    }

    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            bottomSeparator.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.72).cgColor
        }
    }
}
