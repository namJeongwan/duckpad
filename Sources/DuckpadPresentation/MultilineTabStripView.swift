import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
private final class AccessibleTabView: NSView {
    var onPress: (() -> Void)?

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
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?

    override func loadView() {
        let tabView = AccessibleTabView()
        tabView.onPress = { [weak self] in self?.onActivate?() }
        view = tabView
        view.wantsLayer = true
        view.layer?.cornerRadius = 7
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        dirtyLabel.font = .systemFont(ofSize: 7)
        dirtyLabel.textColor = .controlAccentColor
        dirtyLabel.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 16)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dirtyLabel)
        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            dirtyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 9),
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
        titleLabel.stringValue = tab.title
        dirtyLabel.isHidden = !tab.isDirty
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
    }

    @objc private func closePressed() {
        onClose?()
    }
}

@MainActor
public final class MultilineTabStripView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    public struct UpdateMetrics: Equatable {
        public fileprivate(set) var fullReloads = 0
        public fileprivate(set) var itemReloads = 0
    }
    public var onActivate: ((TabID) -> Void)?
    public var onClose: ((TabID) -> Void)?
    public var onAdd: (() -> Void)?
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
    public private(set) var updateMetrics = UpdateMetrics()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        hostedCollectionView.collectionViewLayout = flowLayout
        hostedCollectionView.dataSource = self
        hostedCollectionView.delegate = self
        hostedCollectionView.isSelectable = true
        hostedCollectionView.backgroundColors = [.clear]
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
        flowLayout.itemWidths = tabs.map { tab in
            let width = (tab.title as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: 13)]
            ).width
            return width + 62
        }
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
            return
        case .tabUpdated(let index):
            guard tabs.count == change.snapshot.tabs.count,
                  tabs.indices.contains(index) else {
                apply(tabs: change.snapshot.tabs)
                return
            }
            tabs[index] = change.snapshot.tabs[index]
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
    }

    public var contentHeight: CGFloat { measuredContentHeight }
    public var viewportHeight: CGFloat { heightConstraint.constant }

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
        return tabItem
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let index = indexPaths.first?.item, tabs.indices.contains(index) else { return }
        onActivate?(tabs[index].id)
    }

    private func updateDocumentFrame() {
        let width = max(1, hostedScrollView.contentSize.width)
        let height = max(measuredContentHeight, hostedScrollView.contentSize.height)
        if hostedCollectionView.frame.size != NSSize(width: width, height: height) {
            hostedCollectionView.setFrameSize(NSSize(width: width, height: height))
            flowLayout.invalidateLayout()
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
}
