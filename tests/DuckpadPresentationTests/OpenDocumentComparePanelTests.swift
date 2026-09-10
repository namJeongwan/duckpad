import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadPresentation
import Testing

private final class CompareExecutionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func record(_ value: Bool) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var recordedValues: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class CompareDiffRaceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var entered: Set<String> = []
    let releaseOld = DispatchSemaphore(value: 0)
    let releaseNew = DispatchSemaphore(value: 0)

    func markEntered(_ key: String) {
        lock.lock()
        entered.insert(key)
        lock.unlock()
    }

    func hasEntered(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered.contains(key)
    }
}

private func compareContent(
    left: String = "same\nold\ntail",
    right: String = "same\nnew\ntail"
) -> OpenDocumentCompareContent {
    OpenDocumentCompareContent(
        title: "Compare Open Documents",
        leftTitle: "left.json",
        rightTitle: "right.json",
        leftText: left,
        rightText: right
    )
}

@Test @MainActor func comparePanelRendersFixedReadOnlyRowsWithSemanticMarkers() throws {
    _ = NSApplication.shared
    let content = compareContent()
    let diff = try AlignedLineDiff.build(left: content.leftText, right: content.rightText)
    let panel = OpenDocumentComparePanel(content: content, diff: diff)
    defer { panel.dismiss() }

    #expect(panel.leftTextView.isEditable == false)
    #expect(panel.rightTextView.isEditable == false)
    #expect(panel.leftTextView.isSelectable)
    #expect(panel.rightTextView.isSelectable)
    #expect(panel.leftTextView.textContainer?.widthTracksTextView == false)
    #expect(panel.rightTextView.textContainer?.widthTracksTextView == false)
    #expect(panel.leftRenderedText.contains("~     2  old"))
    #expect(panel.rightRenderedText.contains("~     2  new"))
    #expect(panel.leftVisualRowCount == diff.rows.count)
    #expect(panel.rightVisualRowCount == diff.rows.count)
    #expect(panel.leftChangedRangeCount == 1)
    #expect(panel.rightChangedRangeCount == 1)
    let paragraph = panel.leftTextView.textStorage?.attribute(
        .paragraphStyle,
        at: 0,
        effectiveRange: nil
    ) as? NSParagraphStyle
    #expect(paragraph?.minimumLineHeight == paragraph?.maximumLineHeight)
    #expect((paragraph?.minimumLineHeight ?? 0) > 0)
    #expect(panel.leftTextView.accessibilityLabel()?.contains("read-only") == true)
    #expect(panel.rightTextView.accessibilityHelp()?.contains("markers") == true)
}

@Test @MainActor func comparePanelUsesInsertDeleteMarkersAndAlignedPlaceholders() throws {
    let content = compareContent(left: "head\nremoved\ntail", right: "head\ninserted one\ninserted two\ntail")
    let diff = try AlignedLineDiff.build(left: content.leftText, right: content.rightText)
    let panel = OpenDocumentComparePanel(content: content, diff: diff)
    defer { panel.dismiss() }

    #expect(panel.leftRenderedText.contains("~     2  removed"))
    #expect(panel.rightRenderedText.contains("~     2  inserted one"))
    #expect(panel.rightRenderedText.contains("+     3  inserted two"))
    #expect(panel.leftVisualRowCount == panel.rightVisualRowCount)
    #expect(panel.leftRenderedText.split(separator: "\n", omittingEmptySubsequences: false).count
        == panel.rightRenderedText.split(separator: "\n", omittingEmptySubsequences: false).count)
}

@Test @MainActor func comparePanelKeepsLongUnequalLinesOnOneVisualRow() throws {
    let left = String(repeating: "a", count: 20_000)
    let right = String(repeating: "b", count: 25_000)
    let content = compareContent(left: left, right: right)
    let diff = try AlignedLineDiff.build(left: left, right: right)
    let panel = OpenDocumentComparePanel(content: content, diff: diff)
    defer { panel.dismiss() }

    #expect(panel.leftVisualRowCount == 1)
    #expect(panel.rightVisualRowCount == 1)
    #expect(panel.leftScrollView.hasHorizontalScroller)
    #expect(panel.rightScrollView.hasHorizontalScroller)
    #expect(panel.leftTextView.isHorizontallyResizable)
    #expect(panel.rightTextView.isHorizontallyResizable)
}

@Test @MainActor func comparePanelSynchronizesNormalizedVerticalPositionAndClampsEnds() throws {
    let left = (0..<300).map { "left \($0)" }.joined(separator: "\n")
    let right = (0..<300).map { "right \($0)" }.joined(separator: "\n")
    let content = compareContent(left: left, right: right)
    let panel = OpenDocumentComparePanel(
        content: content,
        diff: try AlignedLineDiff.build(left: left, right: right)
    )
    defer { panel.dismiss() }
    panel.layoutForTesting(size: NSSize(width: 900, height: 520))

    panel.setNormalizedVerticalPosition(0.43, fromLeft: true)
    #expect(abs(panel.leftNormalizedVerticalPosition - 0.43) < 0.02)
    #expect(abs(panel.rightNormalizedVerticalPosition - 0.43) < 0.02)

    panel.setNormalizedVerticalPosition(2, fromLeft: false)
    #expect(panel.leftNormalizedVerticalPosition == 1)
    #expect(panel.rightNormalizedVerticalPosition == 1)
    panel.layoutForTesting(size: NSSize(width: 900, height: 360))
    #expect(panel.leftNormalizedVerticalPosition == 1)
    #expect(panel.rightNormalizedVerticalPosition == 1)

    panel.setNormalizedVerticalPosition(-1, fromLeft: true)
    #expect(panel.leftNormalizedVerticalPosition == 0)
    #expect(panel.rightNormalizedVerticalPosition == 0)
}

@Test @MainActor func comparePanelDoesNotMirrorHorizontalScrolling() throws {
    let long = String(repeating: "0123456789", count: 200)
    let content = compareContent(left: long, right: long + "x")
    let panel = OpenDocumentComparePanel(
        content: content,
        diff: try AlignedLineDiff.build(left: content.leftText, right: content.rightText)
    )
    defer { panel.dismiss() }
    panel.layoutForTesting(size: NSSize(width: 700, height: 320))
    let rightX = panel.rightScrollView.contentView.bounds.origin.x

    panel.leftScrollView.contentView.scroll(to: NSPoint(x: 320, y: 0))
    panel.synchronizeScrollForTesting(fromLeft: true)

    #expect(panel.leftScrollView.contentView.bounds.origin.x > 0)
    #expect(panel.rightScrollView.contentView.bounds.origin.x == rightX)
}

@Test @MainActor func nativePresenterBuildsNontrivialDiffOffMainThread() async throws {
    let probe = CompareExecutionProbe()
    let presenter = NativeOpenDocumentComparePresenter(diffBuilder: { left, right in
        probe.record(Thread.isMainThread)
        return try AlignedLineDiff.build(left: left, right: right)
    })
    let content = compareContent(
        left: (0..<600).map { "left \($0)" }.joined(separator: "\n"),
        right: (0..<600).map { "right \($0)" }.joined(separator: "\n")
    )

    let panel = try await presenter.makePanel(for: content)
    panel.dismiss()

    #expect(probe.recordedValues == [false])
}

@Test @MainActor func olderDiffCompletionCannotClearOrReviveNewerRequest() async throws {
    let probe = CompareDiffRaceProbe()
    let presenter = NativeOpenDocumentComparePresenter(diffBuilder: { left, right in
        if left == "old" {
            probe.markEntered("old")
            probe.releaseOld.wait()
        } else {
            probe.markEntered("new")
            probe.releaseNew.wait()
        }
        return try AlignedLineDiff.build(left: left, right: right)
    })
    var oldFinished = false
    let old = Task { @MainActor in
        if let panel = try? await presenter.makePanel(for: compareContent(left: "old", right: "old!")) {
            panel.dismiss()
        }
        oldFinished = true
    }
    while !probe.hasEntered("old") { await Task.yield() }
    var newError: OpenDocumentComparison.Error?
    let new = Task { @MainActor in
        do {
            let panel = try await presenter.makePanel(for: compareContent(left: "new", right: "new!"))
            panel.dismiss()
        } catch let error as OpenDocumentComparison.Error {
            newError = error
        } catch { }
    }
    while !probe.hasEntered("new") { await Task.yield() }

    probe.releaseOld.signal()
    await old.value
    #expect(oldFinished)
    #expect(presenter.hasPendingDiffForTesting)
    presenter.cancelOutstandingComparisons()
    probe.releaseNew.signal()
    await new.value
    #expect(newError == .cancelled)
}

@Test @MainActor func comparisonOpensAnIndependentDiffWindowWhenParentExists() async throws {
    let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    parent.isReleasedWhenClosed = false
    let content = compareContent()
    let panel = OpenDocumentComparePanel(content: content, diff: try AlignedLineDiff.build(left: content.leftText, right: content.rightText))
    let task = Task { @MainActor in await panel.present(attachedTo: parent) }
    for _ in 0..<30 where panel.window?.isVisible != true { await Task.yield() }
    #expect(panel.window?.isVisible == true)
    #expect(panel.window?.sheetParent == nil)
    #expect(parent.sheets.isEmpty)
    #expect(panel.window?.styleMask.contains(.resizable) == true)
    panel.dismiss()
    await task.value
    parent.close()
}

@Test @MainActor func standalonePanelPresentationAwaitsDismissalAndDismissIsIdempotent() async throws {
    let content = compareContent()
    let panel = OpenDocumentComparePanel(
        content: content,
        diff: try AlignedLineDiff.build(left: content.leftText, right: content.rightText)
    )
    var finished = false
    let presentation = Task { @MainActor in
        await panel.present(attachedTo: nil)
        finished = true
    }
    for _ in 0..<20 { await Task.yield() }
    #expect(finished == false)

    panel.dismiss()
    panel.dismiss()
    await presentation.value

    #expect(finished)
    #expect(panel.dismissTransitionCountForTesting == 1)
}

@Test @MainActor func comparisonMenuRoutesCloseAndCopyToDiffAndRestoresDocumentMenu() async throws {
    let previous = NSApplication.shared.mainMenu
    let content = compareContent()
    let panel = OpenDocumentComparePanel(content: content, diff: try AlignedLineDiff.build(left: content.leftText, right: content.rightText))
    let task = Task { @MainActor in await panel.present(attachedTo: nil) }
    for _ in 0..<30 where panel.window?.isVisible != true { await Task.yield() }
    panel.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    let menu = try #require(NSApplication.shared.mainMenu)
    let close = try #require(menu.items.first { $0.submenu?.title == "File" }?.submenu?.items.first)
    #expect(close.target === panel.window)
    #expect(close.action == #selector(NSWindow.performClose(_:)))
    let copy = try #require(menu.items.first { $0.submenu?.title == "Edit" }?.submenu?.items.first)
    #expect(copy.target == nil)
    #expect(copy.action == #selector(NSText.copy(_:)))
    panel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(NSApplication.shared.mainMenu === previous)
    panel.dismiss()
    await task.value
    #expect(NSApplication.shared.mainMenu === previous)
}

@Test @MainActor func failureSheetIsTrackedAndCancelledWithPresenterTeardown() async throws {
    _ = NSApplication.shared
    let parent = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    parent.isReleasedWhenClosed = false
    let presenter = NativeOpenDocumentComparePresenter()

    presenter.presentFailure(.complexityExceeded(maximumRows: 10), attachedTo: parent)
    #expect(presenter.failureSheetCountForTesting == 1)

    presenter.cancelOutstandingComparisons()
    for _ in 0..<20 { await Task.yield() }
    #expect(presenter.failureSheetCountForTesting == 0)
    #expect(parent.sheets.isEmpty)

    withExtendedLifetime(parent) {
        parent.close()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
}

@Test @MainActor func pickerFiltersSourceAndDisambiguatesDuplicateTitlesWithPaths() {
    let sourceID = TabID()
    let firstID = TabID()
    let secondID = TabID()
    let buffer = { EditorBufferDescriptor(bufferID: BufferID(), revision: 0) }
    let source = TabSnapshot(id: sourceID, title: "same.txt", isActive: true, isDirty: false, isPinned: false, buffer: buffer(), fullPath: "/source/same.txt")
    let candidates = [
        source,
        TabSnapshot(id: firstID, title: "same.txt", isActive: false, isDirty: false, isPinned: false, buffer: buffer(), fullPath: "/one/same.txt"),
        TabSnapshot(id: secondID, title: "same.txt", isActive: false, isDirty: false, isPinned: false, buffer: buffer(), fullPath: "/two/same.txt"),
        TabSnapshot(id: TabID(), title: "unique.md", isActive: false, isDirty: false, isPinned: false, buffer: buffer()),
    ]

    let choices = NativeOpenDocumentComparePresenter.choices(source: source, candidates: candidates)

    #expect(choices.map(\.tabID).contains(sourceID) == false)
    #expect(choices.first(where: { $0.tabID == firstID })?.label == "same.txt — /one/same.txt")
    #expect(choices.first(where: { $0.tabID == secondID })?.label == "same.txt — /two/same.txt")
    #expect(choices.last?.label == "unique.md")

    let sourceDuplicateOnly = NativeOpenDocumentComparePresenter.choices(
        source: source,
        candidates: [source, candidates[1], candidates[3]]
    )
    #expect(sourceDuplicateOnly.first?.label == "same.txt — /one/same.txt")
}

@Test @MainActor func hidingComparisonPreservesThePresentedSnapshotUntilExplicitDismissal() async throws {
    let presenter = NativeOpenDocumentComparePresenter()
    let task = Task { @MainActor in try? await presenter.present(compareContent(), attachedTo: nil, isCurrent: { true }) }
    for _ in 0..<200 where !presenter.hasPresentedSnapshot { try await Task.sleep(for: .milliseconds(10)) }
    #expect(presenter.hasPresentedSnapshot)
    presenter.comparisonWindowForTesting?.orderOut(nil)
    #expect(presenter.hasPresentedSnapshot)
    #expect(!presenter.restoresEditorFocusAfterDismissal)
    presenter.cancelOutstandingComparisons()
    await task.value
    #expect(!presenter.hasPresentedSnapshot)
}
