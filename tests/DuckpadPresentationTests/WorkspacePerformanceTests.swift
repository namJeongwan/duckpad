import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing
@testable import DuckpadPresentation

/// Explicit release-mode gate: DUCKPAD_WORKSPACE_PERFORMANCE=1 swift test -c release --filter WorkspacePerformanceTests
@Suite(.serialized) @MainActor
struct WorkspacePerformanceTests {
    private func milliseconds(_ elapsed: Duration) -> Double {
        let parts = elapsed.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_WORKSPACE_PERFORMANCE"] == "1"))
    func sidebarInteractionBudget() async throws {
        _ = NSApplication.shared
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-workspace-perf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let browser = WorkspaceBrowserUseCase(store: LocalWorkspaceRootStore(archiveURL: fixture.appendingPathComponent("roots.json")))
        let controller = DuckpadWindowController(workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()),
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
            workspaceBrowserUseCase: browser, automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        defer { controller.close() }
        if !controller.workspaceSidebarSmokeState().isVisible { controller.performToggleWorkspaceSidebar() }
        let window = try #require(controller.window), content = try #require(window.contentView)
        window.makeKeyAndOrderFront(nil)
        let sidebar = try #require(views(content).compactMap { $0 as? WorkspaceSidebarView }.first)
        let outline = try #require(views(sidebar).compactMap { $0 as? NSOutlineView }.first)
        let root = WorkspaceRoot(canonicalPath: fixture.path, displayName: "performance-fixture")
        sidebar.apply(roots: [root])
        // A loaded 20,000-file tree. Each of 1,000 directories has one matching file.
        let directories = (0..<1_000).map { "module-\($0)" }
        sidebar.applyChildren(rootID: root.id, relativeDirectory: "", entries: directories.map {
            .init(rootID: root.id, relativePath: $0, name: $0, kind: .directory)
        })
        var matches: [WorkspaceBrowserEntry] = []
        for directory in directories {
            let entries: [WorkspaceBrowserEntry] = (0..<20).map { index in
                let name = index == 0 ? "util.ts" : "source-\(index).ts"
                return .init(rootID: root.id, relativePath: directory + "/" + name, name: name, kind: .file)
            }
            sidebar.applyChildren(rootID: root.id, relativeDirectory: directory, entries: entries)
            matches.append(entries[0])
        }
        let rootNode = try #require(outline.item(atRow: 0))
        outline.expandItem(rootNode)
        let directoryNode = try #require(outline.item(atRow: 1))
        outline.expandItem(directoryNode)
        let originalRows = outline.numberOfRows
        sidebar.search.onLoad = { _ in .init(files: matches, isTruncated: true, skippedDirectoryCount: 0) }
        defer { sidebar.search.stop() }
        content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        var timings: [String: [Double]] = [:]
        func measure(_ name: String, _ operation: () -> Void) {
            let start = ContinuousClock.now
            operation()
            content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            timings[name, default: []].append(milliseconds(start.duration(to: .now)))
        }
        for _ in 0..<12 {
            #expect(window.makeFirstResponder(outline))
            measure("filter_show") { controller.performShowFind() }
            measure("filter_hide_empty") { controller.performShowFind() }
            controller.performShowFind()
            measure("filter_input") { sidebar.search.setQuery("util") }
            measure("filter_render_1000_matches") {
                sidebar.search.onResults?(.init(files: matches, isTruncated: true, skippedDirectoryCount: 0))
            }
            #expect(outline.numberOfRows == 2_001)
            measure("filter_hide_restore_20000_loaded_files") { controller.performShowFind() }
            #expect(outline.numberOfRows == originalRows)
            measure("directory_collapse") { outline.collapseItem(directoryNode) }
            measure("directory_expand") { outline.expandItem(directoryNode) }
        }
        // Also restore a normal tree with 50 expanded directories (2,001 visible rows).
        let expanded = WorkspaceRoot(id: root.id, canonicalPath: root.canonicalPath, displayName: root.displayName,
            isAvailable: true, expandedRelativePaths: [""] + Array(directories.prefix(50)), selectedRelativePath: nil)
        sidebar.restoreNavigation(for: expanded)
        #expect(outline.numberOfRows == 2_001)
        for _ in 0..<12 {
            #expect(window.makeFirstResponder(outline))
            controller.performShowFind()
            sidebar.search.setQuery("util")
            sidebar.search.onResults?(.init(files: matches, isTruncated: true, skippedDirectoryCount: 0))
            measure("filter_hide_restore_50_expanded_directories") { controller.performShowFind() }
            #expect(outline.numberOfRows == 2_001)
        }
        for name in timings.keys.sorted() {
            let values = try #require(timings[name]), warm = Array(values.dropFirst()).sorted()
            let p95 = warm[Int(ceil(Double(warm.count) * 0.95)) - 1]
            print("DUCKPAD_WORKSPACE_PERF metric=\(name) first_ms=\(values[0]) p95_ms=\(p95) max_ms=\(values.max()!) samples=\(values.count)")
            #expect(values[0] < 50, "\(name) first interaction exceeds 50ms wall-time budget")
            #expect(p95 < 50, "\(name) exceeds 50ms wall-time budget")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_WORKSPACE_PERFORMANCE"] == "1"))
    func fileSystemSearchTiming() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-workspace-index-perf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for index in 0..<1_000 {
            let directory = fixture.appendingPathComponent("module-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in 0..<20 {
                let name = file == 0 ? "util.ts" : "source-\(file).ts"
                try Data().write(to: directory.appendingPathComponent(name))
            }
        }
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ripgrep/15.1.0/native/rg")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        let indexer = LocalFolderFileNameIndex(executable: executable)
        for iteration in 0..<3 {
            let start = ContinuousClock.now
            let result = try await indexer.search(in: fixture, query: "util", maximumEntries: 1_000, includeHiddenFiles: false)
            print("DUCKPAD_WORKSPACE_PERF metric=rg_search_20000_files iteration=\(iteration) matches=\(result.relativePaths.count) total_ms=\(milliseconds(start.duration(to: .now)))")
            #expect(result.relativePaths.count == 1_000)
        }
        // Exercise real debounce, asynchronous rg completion, UI delivery and layout.
        _ = NSApplication.shared
        let sidebar = WorkspaceSidebarView(frame: .init(x: 0, y: 0, width: 220, height: 600))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sidebar
        window.makeKeyAndOrderFront(nil)
        defer { sidebar.search.stop(); window.close() }
        let root = WorkspaceRoot(canonicalPath: fixture.path, displayName: "performance-fixture")
        sidebar.apply(roots: [root])
        sidebar.toggleFilter()
        sidebar.search.onLoad = { query in
            let result = try await indexer.search(in: fixture, query: query, maximumEntries: 1_000, includeHiddenFiles: false)
            return .init(files: result.relativePaths.map {
                .init(rootID: root.id, relativePath: $0, name: URL(fileURLWithPath: $0).lastPathComponent, kind: .file)
            }, isTruncated: result.isTruncated, skippedDirectoryCount: result.skippedCount)
        }
        var ready = false
        let apply = sidebar.search.onResults
        sidebar.search.onResults = { result in
            let start = ContinuousClock.now
            apply?(result)
            if result?.files.isEmpty == false {
                sidebar.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let elapsed = milliseconds(start.duration(to: .now))
                print("DUCKPAD_WORKSPACE_PERF metric=async_result_apply_1000_matches total_ms=\(elapsed)")
                #expect(elapsed < 50)
                ready = true
            }
        }
        for iteration in 0..<3 {
            ready = false
            let start = ContinuousClock.now
            sidebar.search.setQuery("util")
            let deadline = start + .seconds(5)
            while !ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
            #expect(ready)
            print("DUCKPAD_WORKSPACE_PERF metric=query_to_result_including_120ms_debounce iteration=\(iteration) total_ms=\(milliseconds(start.duration(to: .now)))")
        }
    }
}
