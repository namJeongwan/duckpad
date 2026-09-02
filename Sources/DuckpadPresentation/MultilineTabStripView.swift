import AppKit
import DuckpadApplication
import DuckpadDomain

public enum TabContextAction: Equatable, Sendable {
    case close(TabCloseScope)
    case setPinned(Bool)
    case copyFullPath
    case openContainingFolder
}

@MainActor
private final class AccessibleTabView: NSView {
    var onPress: (() -> Void)?
    var onMiddleClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

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
    private let titleLabel = NSTextField(labelWithString: "")
    private let dirtyLabel = NSTextField(labelWithString: "●")
    private let pinLabel = NSTextField(labelWithString: "◆")
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    var onContextAction: ((TabContextAction) -> Void)?
    private var configuredTab: TabSnapshot?

    override func loadView() {
        let tabView = AccessibleTabView()
        tabView.onPress = { [weak self] in self?.onActivate?() }
        tabView.onMiddleClick = { [weak self] in self?.onClose?() }
        tabView.menuProvider = { [weak self] in self?.makeContextMenu() }
        view = tabView
        view.wantsLayer = true
        view.layer?.cornerRadius = 7
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        dirtyLabel.font = .systemFont(ofSize: 7)
        dirtyLabel.textColor = .controlAccentColor
        dirtyLabel.translatesAutoresizingMaskIntoConstraints = false
        pinLabel.font = .systemFont(ofSize: 7)
        pinLabel.textColor = .secondaryLabelColor
        pinLabel.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 16)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dirtyLabel)
        view.addSubview(pinLabel)
        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            pinLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            pinLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            pinLabel.widthAnchor.constraint(equalToConstant: 8),
            dirtyLabel.leadingAnchor.constraint(equalTo: pinLabel.trailingAnchor, constant: 2),
            dirtyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            dirtyLabel.widthAnchor.constraint(equalToConstant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: dirtyLabel.trailingAnchor, constant: 3),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            closeButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
        ])
    }

    func configure(tab: TabSnapshot, index: Int, row: Int) {
        configuredTab = tab
        titleLabel.stringValue = tab.title
        dirtyLabel.isHidden = !tab.isDirty
        pinLabel.isHidden = !tab.isPinned
        titleLabel.toolTip = tab.fullPath ?? tab.title
        view.toolTip = tab.fullPath ?? tab.title
        view.layer?.backgroundColor = (
            tab.isActive ? NSColor.selectedContentBackgroundColor : NSColor.controlBackgroundColor
        ).withAlphaComponent(tab.isActive ? 0.30 : 0.65).cgColor

        let stableID = tab.id.rawValue.uuidString.lowercased()
        let state = [
            tab.isActive ? "selected" : "not selected",
            tab.isDirty ? "modified" : "unmodified",
            tab.isPinned ? "pinned" : "not pinned",
            "index \(index + 1)",
            "row \(row + 1)",
        ].joined(separator: ", ")
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityIdentifier("duckpad.tab.\(stableID)")
        view.setAccessibilityLabel("\(tab.title) tab")
        view.setAccessibilityValue(state)
        view.setAccessibilityHelp("Activate \(tab.title) tab")
        closeButton.setAccessibilityIdentifier("duckpad.tab.close.\(stableID)")
        closeButton.setAccessibilityLabel("Close \(tab.title)")
        closeButton.setAccessibilityValue(tab.isDirty ? "modified tab" : "unmodified tab")
        view.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Close \(tab.title)") { [weak self] in
                self?.onClose?()
                return true
            },
            NSAccessibilityCustomAction(name: tab.isPinned ? "Unpin \(tab.title)" : "Pin \(tab.title)") { [weak self] in
                self?.onContextAction?(.setPinned(!tab.isPinned))
                return true
            },
        ])
    }

    @objc private func closePressed() {
        onClose?()
    }

    private func makeContextMenu() -> NSMenu? {
        guard let tab = configuredTab else { return nil }
        let menu = NSMenu(title: tab.title)
        add("Close", action: #selector(closeCurrent), to: menu)
        add("Close Others", action: #selector(closeOthers), to: menu)
        add("Close to Right", action: #selector(closeRight), to: menu)
        menu.addItem(.separator())
        add(tab.isPinned ? "Unpin Tab" : "Pin Tab", action: #selector(togglePinned), to: menu)
        if tab.fullPath != nil {
            menu.addItem(.separator())
            add("Copy Full Path", action: #selector(copyFullPath), to: menu)
            add("Open Containing Folder", action: #selector(openContainingFolder), to: menu)
        }
        return menu
    }

    func contextMenu() -> NSMenu? { makeContextMenu() }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func closeCurrent() { onContextAction?(.close(.current)) }
    @objc private func closeOthers() { onContextAction?(.close(.others)) }
    @objc private func closeRight() { onContextAction?(.close(.right)) }
    @objc private func togglePinned() {
        guard let tab = configuredTab else { return }
        onContextAction?(.setPinned(!tab.isPinned))
    }
    @objc private func copyFullPath() { onContextAction?(.copyFullPath) }
    @objc private func openContainingFolder() { onContextAction?(.openContainingFolder) }
}

@MainActor
public final class MultilineTabStripView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private static let tabPasteboardType = NSPasteboard.PasteboardType("com.duckpad.tab-id")
    public struct UpdateMetrics: Equatable {
        public fileprivate(set) var fullReloads = 0
        public fileprivate(set) var itemReloads = 0
    }
    public var onActivate: ((TabID) -> Void)?
    public var onClose: ((TabID) -> Void)?
    public var onAdd: (() -> Void)?
    public var onMove: ((TabID, Int) -> Void)?
    public var onContextAction: ((TabID, TabContextAction) -> Void)?
    public var viewportPolicy = TabStripViewportPolicy() {
        didSet { updateViewportHeight() }
    }

    let hostedCollectionView = NSCollectionView()
    let hostedScrollView = NSScrollView()
    let flowLayout = MultilineTabCollectionLayout()
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private var tabs: [TabSnapshot] = []
    private var heightConstraint: NSLayoutConstraint!
    private var measuredContentHeight: CGFloat = 42
    private var isSynchronizingSelection = false
    public private(set) var updateMetrics = UpdateMetrics()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        hostedCollectionView.collectionViewLayout = flowLayout
        hostedCollectionView.dataSource = self
        hostedCollectionView.delegate = self
        hostedCollectionView.isSelectable = true
        hostedCollectionView.backgroundColors = [.clear]
        hostedCollectionView.registerForDraggedTypes([Self.tabPasteboardType])
        hostedCollectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        hostedCollectionView.setAccessibilityIdentifier("duckpad.tab.collection")
        hostedCollectionView.setAccessibilityLabel("Open document tabs")
        hostedCollectionView.register(
            DuckpadTabItem.self,
            forItemWithIdentifier: DuckpadTabItem.identifier
        )
        hostedCollectionView.frame = NSRect(x: 0, y: 0, width: 1, height: 42)
        hostedCollectionView.autoresizingMask = [.width]

        hostedScrollView.documentView = hostedCollectionView
        hostedScrollView.drawsBackground = false
        hostedScrollView.hasVerticalScroller = true
        hostedScrollView.hasHorizontalScroller = false
        hostedScrollView.autohidesScrollers = true
        hostedScrollView.borderType = .noBorder
        hostedScrollView.translatesAutoresizingMaskIntoConstraints = false
        hostedScrollView.setAccessibilityIdentifier("duckpad.tab.overflow")
        hostedScrollView.setAccessibilityLabel("Multiline tab rows")

        addButton.target = self
        addButton.action = #selector(addPressed)
        addButton.bezelStyle = .texturedRounded
        addButton.toolTip = "New Scratch Tab"
        addButton.setAccessibilityIdentifier("duckpad.tab.add")
        addButton.setAccessibilityLabel("New Scratch Tab")
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostedScrollView)
        addSubview(addButton)
        heightConstraint = heightAnchor.constraint(equalToConstant: 42)
        NSLayoutConstraint.activate([
            heightConstraint,
            hostedScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostedScrollView.topAnchor.constraint(equalTo: topAnchor),
            hostedScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostedScrollView.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -4),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            addButton.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            addButton.widthAnchor.constraint(equalToConstant: 30),
            addButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        flowLayout.onContentHeightChange = { [weak self] height in
            guard let self else { return }
            measuredContentHeight = height
            updateDocumentFrame()
            updateViewportHeight()
            refreshVisibleItems()
            scrollSelectedTabVisible()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        updateDocumentFrame()
        updateViewportHeight()
        refreshVisibleItems()
    }

    public func apply(tabs: [TabSnapshot]) {
        self.tabs = tabs
        flowLayout.itemWidths = tabs.map(tabWidth)
        hostedCollectionView.reloadData()
        updateMetrics.fullReloads += 1
        hostedCollectionView.selectionIndexPaths = Set(
            tabs.enumerated().compactMap {
                $0.element.isActive ? IndexPath(item: $0.offset, section: 0) : nil
            }
        )
        flowLayout.invalidateLayout()
        hostedCollectionView.layoutSubtreeIfNeeded()
        updateDocumentFrame()
        updateViewportHeight()
        refreshVisibleItems()
        scrollSelectedTabVisible()
    }

    public func apply(change: WorkspaceChange) {
        switch change.kind {
        case .persistence:
            synchronizeSelection(with: change.snapshot)
            refreshVisibleItems()
            scrollSelectedTabVisible()
            return
        case .tabUpdated(let index):
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
            hostedCollectionView.selectionIndexPaths = Set(
                tabs.enumerated().compactMap {
                    $0.element.isActive ? IndexPath(item: $0.offset, section: 0) : nil
                }
            )
        default:
            apply(tabs: change.snapshot.tabs)
        }
    }

    public func setInteractionsEnabled(_ isEnabled: Bool) {
        hostedCollectionView.isSelectable = isEnabled
        addButton.isEnabled = isEnabled
    }

    func tearDownHostedViews() {
        flowLayout.onContentHeightChange = nil
        hostedCollectionView.dataSource = nil
        hostedCollectionView.delegate = nil
        hostedScrollView.documentView = nil
        hostedCollectionView.collectionViewLayout = nil
        onActivate = nil
        onClose = nil
        onAdd = nil
        onMove = nil
        onContextAction = nil
    }

    public var contentHeight: CGFloat { measuredContentHeight }
    public var viewportHeight: CGFloat { heightConstraint.constant }
    public var rowCount: Int { flowLayout.rowCount }

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
        let row = flowLayout.row(forItemAt: indexPath.item) ?? 0
        tabItem.configure(tab: tab, index: indexPath.item, row: row)
        tabItem.onActivate = { [weak self] in self?.onActivate?(tab.id) }
        tabItem.onClose = { [weak self] in self?.onClose?(tab.id) }
        tabItem.onContextAction = { [weak self] action in self?.onContextAction?(tab.id, action) }
        return tabItem
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard !isSynchronizingSelection else { return }
        guard let index = indexPaths.first?.item, tabs.indices.contains(index) else { return }
        onActivate?(tabs[index].id)
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> (any NSPasteboardWriting)? {
        guard tabs.indices.contains(indexPath.item) else { return nil }
        let item = NSPasteboardItem()
        item.setString(tabs[indexPath.item].id.rawValue.uuidString, forType: Self.tabPasteboardType)
        return item
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        proposedDropOperation.pointee = .before
        return .move
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        acceptDrop(from: draggingInfo.draggingPasteboard, insertionIndex: indexPath.item)
    }

    func acceptDrop(from pasteboard: NSPasteboard, insertionIndex: Int) -> Bool {
        guard let value = pasteboard.string(forType: Self.tabPasteboardType),
              let uuid = UUID(uuidString: value), !tabs.isEmpty else { return false }
        let tabID = TabID(rawValue: uuid)
        guard let source = tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        guard let destination = TabDropDestination.finalIndex(
            sourceIndex: source,
            insertionIndex: min(insertionIndex, tabs.count),
            itemCount: tabs.count
        ) else { return false }
        performDrop(tabID: tabID, to: destination)
        return true
    }

    public func performDrop(tabID: TabID, to index: Int) {
        guard tabs.contains(where: { $0.id == tabID }), tabs.indices.contains(index) else { return }
        onMove?(tabID, index)
    }

    public func performMiddleClick(tabID: TabID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        onClose?(tabID)
    }

    public func contextMenu(for tabID: TabID) -> NSMenu? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let item = hostedCollectionView.item(at: IndexPath(item: index, section: 0)) as? DuckpadTabItem else {
            return nil
        }
        return item.contextMenu()
    }

    private func updateDocumentFrame() {
        let width = max(1, hostedScrollView.contentSize.width)
        let height = max(measuredContentHeight, hostedScrollView.contentSize.height)
        if hostedCollectionView.frame.size != NSSize(width: width, height: height) {
            let widthChanged = hostedCollectionView.frame.width != width
            hostedCollectionView.setFrameSize(NSSize(width: width, height: height))
            if widthChanged { flowLayout.invalidateLayout() }
        }
    }

    private func updateViewportHeight() {
        let workspaceHeight = max(1, superview?.bounds.height ?? window?.contentLayoutRect.height ?? 620)
        heightConstraint.constant = viewportPolicy.height(
            contentHeight: measuredContentHeight,
            workspaceHeight: workspaceHeight,
            engine: flowLayout.engine
        )
    }

    private func scrollSelectedTabVisible() {
        guard let index = tabs.firstIndex(where: \.isActive),
              let attributes = flowLayout.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
              ) else {
            return
        }
        hostedCollectionView.scroll(attributes.frame.origin)
        hostedCollectionView.scrollToItems(
            at: [IndexPath(item: index, section: 0)],
            scrollPosition: .centeredVertically
        )
    }

    private func synchronizeSelection(with snapshot: WorkspaceSnapshot) {
        let authoritative = Set(snapshot.tabs.enumerated().compactMap {
            $0.element.isActive ? IndexPath(item: $0.offset, section: 0) : nil
        })
        guard hostedCollectionView.selectionIndexPaths != authoritative else { return }
        isSynchronizingSelection = true
        hostedCollectionView.selectionIndexPaths = authoritative
        isSynchronizingSelection = false
    }

    private func refreshVisibleItems() {
        for case let item as DuckpadTabItem in hostedCollectionView.visibleItems() {
            guard let path = hostedCollectionView.indexPath(for: item),
                  tabs.indices.contains(path.item) else {
                continue
            }
            item.configure(
                tab: tabs[path.item],
                index: path.item,
                row: flowLayout.row(forItemAt: path.item) ?? 0
            )
        }
    }

    @objc private func addPressed() {
        onAdd?()
    }

    private func tabWidth(_ tab: TabSnapshot) -> CGFloat {
        let width = (tab.title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13)]
        ).width
        return width + (tab.isPinned ? 76 : 64)
    }
}
