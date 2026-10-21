import AppKit
import DuckpadApplication
import DuckpadDomain
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct WorkspaceTreeSearchTests {
    private func outline(_ view: NSView) -> NSOutlineView? {
        (view as? NSOutlineView) ?? view.subviews.lazy.compactMap(outline).first
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate())
    }
    @Test func sidebarSearchBuildsAncestorsWithoutOverwritingNormalNavigation() async throws {
        _ = NSApplication.shared
        let sidebar = WorkspaceSidebarView(frame: .init(x: 0, y: 0, width: 220, height: 600))
        let root = WorkspaceRoot(canonicalPath: "/project", displayName: "project")
        _ = sidebar.apply(roots: [root])
        sidebar.applyChildren(rootID: root.id, relativeDirectory: "", entries: [
            .init(rootID: root.id, relativePath: "normal.txt", name: "normal.txt", kind: .file)
        ])
        let tree = try #require(outline(sidebar))
        tree.expandItem(tree.item(atRow: 0))
        let before = tree.numberOfRows
        var navigationWrites = 0
        sidebar.onNavigationChange = { _, _, _ in navigationWrites += 1 }
        sidebar.search.onLoad = { _ in .init(files: [
            .init(rootID: root.id, relativePath: "src/deep/utils.ts", name: "utils.ts", kind: .file)
        ], isTruncated: false, skippedDirectoryCount: 0) }
        defer { sidebar.search.stop() }
        sidebar.search.setQuery("utils.ts")
        try await wait { tree.numberOfRows == 4 }
        #expect((tree.item(atRow: 3) as? WorkspaceSidebarNode)?.name == "utils.ts")
        #expect(navigationWrites == 0)
        if let path = ProcessInfo.processInfo.environment["DUCKPAD_WORKSPACE_SEARCH_SNAPSHOT"] {
            let window = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua); window.contentView = sidebar
            sidebar.layoutSubtreeIfNeeded()
            let bitmap = try #require(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
            sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
            window.close()
        }
        sidebar.search.setQuery("")
        #expect(tree.numberOfRows == before)
        #expect((tree.item(atRow: 1) as? WorkspaceSidebarNode)?.name == "normal.txt")
        #expect(navigationWrites == 0)
    }
    @Test func filenameQueryIsForwardedAndLateResultsDoNotReplaceNewerQueries() async throws {
        _ = NSApplication.shared
        let panel = FileNameSearchController(); defer { panel.dismiss() }
        var queries: [String] = [], releaseOld = false
        panel.onSearchRequest = { _, _, text in
            queries.append(text)
            if text == "old.ts" { while !releaseOld { await Task.yield() } }
            return (text == "utils.ts" ? [.init(name: "utils.ts", path: "/project/src/utils.ts", target: .tab(TabID()))] : [], false, 0)
        }
        panel.present(in: nil, initial: [])
        panel.setQuery("old.ts")
        try await wait { queries.last == "old.ts" }
        panel.setQuery("utils.ts")
        try await wait { panel.results.first?.name == "utils.ts" }
        releaseOld = true
        for _ in 0..<5 { await Task.yield() }
        #expect(panel.results.first?.name == "utils.ts")
        #expect(queries.contains("utils.ts"))
        panel.setQuery("absent.ts")
        try await wait { queries.last == "absent.ts" }
        #expect(panel.results.isEmpty)
    }

    @Test func rebuildingNormalNodesDuringSearchPreservesNavigationByPath() async throws {
        _ = NSApplication.shared
        let sidebar = WorkspaceSidebarView(frame: .init(x: 0, y: 0, width: 220, height: 600))
        let root = WorkspaceRoot(canonicalPath: "/project", displayName: "project")
        let entry = WorkspaceBrowserEntry(rootID: root.id, relativePath: "normal.txt", name: "normal.txt", kind: .file)
        _ = sidebar.apply(roots: [root]); sidebar.applyChildren(rootID: root.id, relativeDirectory: "", entries: [entry])
        let tree = try #require(outline(sidebar)); tree.expandItem(tree.item(atRow: 0))
        tree.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        sidebar.search.onLoad = { _ in .init(files: [entry], isTruncated: false, skippedDirectoryCount: 0) }
        defer { sidebar.search.stop() }
        sidebar.search.setQuery("normal")
        try await wait { tree.numberOfRows == 2 }
        let navigation = sidebar.invalidateChildren()
        #expect(navigation.first?.expandedRelativePaths == [""])
        #expect(navigation.first?.selectedRelativePath == "normal.txt")
        _ = sidebar.apply(roots: navigation)
        sidebar.applyChildren(rootID: root.id, relativeDirectory: "", entries: [entry])
        sidebar.search.refresh(); sidebar.search.setQuery("")
        #expect(tree.numberOfRows == 2)
        #expect((tree.item(atRow: tree.selectedRow) as? WorkspaceSidebarNode)?.relativePath == "normal.txt")
    }

    @Test func rootChangesDuringSearchCannotRestoreRemovedRootsOrDropNewRoots() async throws {
        _ = NSApplication.shared
        let sidebar = WorkspaceSidebarView(frame: .zero)
        let a = WorkspaceRoot(canonicalPath: "/a", displayName: "a")
        let removed = WorkspaceRoot(canonicalPath: "/removed", displayName: "removed")
        let added = WorkspaceRoot(canonicalPath: "/added", displayName: "added")
        _ = sidebar.apply(roots: [a, removed])
        sidebar.search.onLoad = { _ in .init(files: [], isTruncated: false, skippedDirectoryCount: 0) }
        defer { sidebar.search.stop() }
        sidebar.search.setQuery("utils.ts")
        _ = sidebar.apply(roots: [a, added])
        let navigation = sidebar.invalidateChildren()
        #expect(navigation.map(\.id) == [a.id, added.id])
        _ = sidebar.apply(roots: navigation)
        sidebar.search.setQuery("")
        #expect(try #require(outline(sidebar)).numberOfRows == 2)
    }
}
