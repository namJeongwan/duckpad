import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadPresentation
import Testing

@MainActor
private func insertionRefreshTab(_ title: String, isActive: Bool) -> TabSnapshot {
    TabSnapshot(
        id: TabID(),
        title: title,
        isActive: isActive,
        isDirty: false,
        isPinned: false,
        buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    )
}

@MainActor
private func insertionRefreshSnapshot(_ tabs: [TabSnapshot]) -> WorkspaceSnapshot {
    WorkspaceSnapshot(
        sessionID: SessionID(),
        tabs: tabs,
        activeBuffer: tabs.first(where: \.isActive)?.buffer,
        persistence: .saved,
        startup: .ready
    )
}

@MainActor
private func hostInsertionRefreshStrip(
    tabs: [TabSnapshot]
) -> (NSWindow, MultilineTabStripView) {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    let root = NSView(frame: window.contentView?.bounds ?? .zero)
    let strip = MultilineTabStripView(frame: .zero)
    root.addSubview(strip)
    NSLayoutConstraint.activate([
        strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        strip.topAnchor.constraint(equalTo: root.topAnchor),
    ])
    window.contentView = root
    strip.apply(tabs: tabs)
    root.layoutSubtreeIfNeeded()
    strip.layoutSubtreeIfNeeded()
    strip.hostedCollectionView.layoutSubtreeIfNeeded()
    return (window, strip)
}

@Test @MainActor func validMiddleTabInsertionUpdatesOnlyTheNewCollectionItem() {
    let first = insertionRefreshTab("First", isActive: true)
    let second = insertionRefreshTab("Second", isActive: false)
    let third = insertionRefreshTab("Third", isActive: false)
    let (window, strip) = hostInsertionRefreshStrip(tabs: [first, second, third])
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    let inserted = insertionRefreshTab("Inserted", isActive: true)
    let inactiveFirst = TabSnapshot(
        id: first.id,
        title: first.title,
        isActive: false,
        isDirty: first.isDirty,
        isPinned: first.isPinned,
        buffer: first.buffer
    )
    let updated = [inactiveFirst, inserted, second, third]
    let before = strip.updateMetrics
    let switcherBefore = strip.documentSwitcher.updateMetrics
    var activated: [TabID] = []
    strip.onActivate = { activated.append($0) }

    strip.apply(change: WorkspaceChange(
        snapshot: insertionRefreshSnapshot(updated),
        kind: .tabInserted(index: 1)
    ))

    #expect(strip.updateMetrics.fullReloads == before.fullReloads)
    #expect(strip.updateMetrics.itemInsertions == before.itemInsertions + 1)
    #expect(strip.updateMetrics.itemReloads == before.itemReloads + 1)
    #expect(strip.tabIDs == [first.id, inserted.id, second.id, third.id])
    #expect(strip.activeTabID == inserted.id)
    #expect(strip.hostedCollectionView.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
    #expect(strip.hostedCollectionView.numberOfItems(inSection: 0) == 4)
    let insertedItem = strip.hostedCollectionView.item(
        at: IndexPath(item: 1, section: 0)
    )
    #expect(insertedItem?.view.accessibilityIdentifier() == "duckpad.tab.\(inserted.id.rawValue.uuidString.lowercased())")
    #expect(strip.flowLayout.itemWidths.count == 4)
    #expect(strip.flowLayout.layoutAttributesForItem(at: IndexPath(item: 3, section: 0)) != nil)
    #expect(activated.isEmpty)
    #expect(!strip.hostedScrollView.hasHorizontalScroller)
    #expect(!strip.hostedScrollView.hasVerticalScroller)
    #expect(strip.documentSwitcher.updateMetrics.fullRebuilds == switcherBefore.fullRebuilds + 1)
}

@Test @MainActor func staleWidthCacheFallsBackBeforeCollectionInsertion() {
    let first = insertionRefreshTab("First", isActive: true)
    let second = insertionRefreshTab("Second", isActive: false)
    let third = insertionRefreshTab("Third", isActive: false)
    let (window, strip) = hostInsertionRefreshStrip(tabs: [first, second, third])
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    let inserted = insertionRefreshTab("Inserted", isActive: false)
    strip.flowLayout.itemWidths = [80]
    let before = strip.updateMetrics

    strip.apply(change: WorkspaceChange(
        snapshot: insertionRefreshSnapshot([first, inserted, second, third]),
        kind: .tabInserted(index: 1)
    ))

    #expect(strip.updateMetrics.fullReloads == before.fullReloads + 1)
    #expect(strip.updateMetrics.itemInsertions == before.itemInsertions)
    #expect(strip.hostedCollectionView.numberOfItems(inSection: 0) == 4)
    #expect(strip.flowLayout.itemWidths.count == 4)
    #expect(strip.flowLayout.layoutAttributesForItem(at: IndexPath(item: 3, section: 0)) != nil)
}

@Test @MainActor func tabLayoutInsertsOnlyAtAValidCacheIndex() {
    let layout = MultilineTabCollectionLayout()
    layout.itemWidths = [80, 120]

    #expect(layout.insertItemWidth(100, at: 1))
    #expect(!layout.insertItemWidth(140, at: -1))
    #expect(!layout.insertItemWidth(160, at: 4))

    #expect(layout.itemWidths == [80, 100, 120])
}

@Test @MainActor func malformedTabInsertionFallsBackToOneFullSnapshotRefresh() {
    let first = insertionRefreshTab("First", isActive: true)
    let second = insertionRefreshTab("Second", isActive: false)
    let third = insertionRefreshTab("Third", isActive: false)
    let (window, strip) = hostInsertionRefreshStrip(tabs: [first, second, third])
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    let inserted = insertionRefreshTab("Inserted", isActive: false)
    let updated = [first, inserted, third, second]
    let before = strip.updateMetrics
    let switcherBefore = strip.documentSwitcher.updateMetrics

    strip.apply(change: WorkspaceChange(
        snapshot: insertionRefreshSnapshot(updated),
        kind: .tabInserted(index: 1)
    ))

    #expect(strip.updateMetrics.fullReloads == before.fullReloads + 1)
    #expect(strip.updateMetrics.itemInsertions == before.itemInsertions)
    #expect(strip.tabIDs == [first.id, inserted.id, third.id, second.id])
    #expect(strip.activeTabID == first.id)
    #expect(strip.documentSwitcher.updateMetrics.fullRebuilds == switcherBefore.fullRebuilds + 1)
}

@Test @MainActor func insertionThenPendingDeletionKeepsLayoutCacheCoherent() {
    let first = insertionRefreshTab("First", isActive: true)
    let second = insertionRefreshTab("Second", isActive: false)
    let third = insertionRefreshTab("Third", isActive: false)
    let (window, strip) = hostInsertionRefreshStrip(tabs: [first, second, third])
    defer {
        strip.tearDownHostedViews()
        window.contentView = nil
        window.close()
    }
    let inserted = insertionRefreshTab("Inserted", isActive: false)
    let insertedTabs = [first, inserted, second, third]
    strip.apply(change: WorkspaceChange(
        snapshot: insertionRefreshSnapshot(insertedTabs),
        kind: .tabInserted(index: 1)
    ))

    strip.apply(change: WorkspaceChange(
        snapshot: insertionRefreshSnapshot([first, second, third]),
        kind: .tabRemovalPending(index: 1)
    ))
    strip.hostedCollectionView.layoutSubtreeIfNeeded()

    #expect(strip.hostedCollectionView.numberOfItems(inSection: 0) == 3)
    #expect(strip.flowLayout.itemWidths.count == 3)
    #expect(strip.flowLayout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)) != nil)
    #expect(strip.flowLayout.layoutAttributesForItem(at: IndexPath(item: 3, section: 0)) == nil)
}
