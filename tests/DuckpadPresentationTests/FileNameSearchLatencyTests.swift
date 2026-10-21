import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct FileNameSearchLatencyTests {
    @Test func allShowsUsableResultsBeforeExhaustiveSearchFinishes() async throws {
        _ = NSApplication.shared
        let store = GatedNameStore()
        let browser = WorkspaceBrowserUseCase(store: store)
        _ = await browser.start()
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let coordinator = SearchExperienceCoordinator(workspace: workspace, search: nil, folderSearch: nil,
            files: nil, browser: browser, parent: nil, actionable: { true }, openWorkspace: { _ in },
            activate: { _ in }, onGesture: {}, chooseFolder: { _ in nil })
        defer { coordinator.tearDown() }
        let panel = coordinator.filePanel
        panel.configureWorkspace(browser.roots)
        panel.present(in: nil, initial: [])
        panel.setQuery("util")
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await store.fullSearchStarted), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await store.fullSearchStarted)
        // Completion is explicitly held: this must not depend on filesystem timing.
        #expect(panel.results.map(\.name) == ["util.ts"])
        await store.finish()
        while panel.results.first?.name != "util", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(panel.results.first?.name == "util") // better-ranked late result is retained
    }

    @Test func progressKeepsRowsAndSelectionUntilCompletionAndRejectsStaleQueries() async throws {
        _ = NSApplication.shared
        let panel = FileNameSearchController(); defer { panel.dismiss() }
        func entry(_ name: String) -> FileNameSearchEntry { .init(name: name, path: "/project/" + name, target: .tab(TabID())) }
        let a = entry("util-a"), b = entry("util-b"), c = entry("util-c"), newer = entry("new.ts")
        var stage = 0, delivered = 0, releaseOld = false
        var send: FileNameSearchProgress?
        defer { releaseOld = true }
        panel.onProgressSearchRequest = { _, _, text, publish in
            if text != "util" { return (text == "new" ? [newer] : [], false, 0) }
            send = publish
            publish(([a, b], true, 0)); delivered = 1
            while stage < 1 { try await Task.sleep(for: .milliseconds(5)) }
            publish(([a, b, c], true, 0)); delivered = 2
            // Intentionally ignore cancellation to exercise generation rejection.
            while !releaseOld { await Task.yield() }
            publish(([a], true, 0))
            return ([a], false, 0)
        }
        panel.present(in: nil, initial: []); panel.setQuery("util")
        let deadline = ContinuousClock.now + .seconds(3)
        while delivered < 1, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(panel.results.map(\.name) == [a.name, b.name])
        let table = try #require(panel.window?.contentView?.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }.first)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        stage = 1
        while delivered < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(panel.results.map(\.name) == [a.name, b.name, c.name])
        #expect(panel.results[table.selectedRow].path == b.path)
        let large = [a, b, c] + (0..<600).map { entry("util-extra-\($0)") }
        send?((large, true, 0)) // starts detached ranking; UI rows stay usable
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        while panel.results.count != 100, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(panel.results.count == 100)
        #expect(panel.results[table.selectedRow].path == c.path) // the user's new selection wins
        let request = panel.onProgressSearchRequest
        panel.onProgressSearchRequest = nil // exercise local query ranking without a second backend request
        panel.setQuery("extra")
        #expect(panel.results.count < 100)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let chosen = panel.results[table.selectedRow].path
        while panel.results.count != 100, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(panel.results[table.selectedRow].path == chosen)
        panel.onProgressSearchRequest = request
        panel.setQuery("new")
        while panel.results.first?.name != newer.name, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        releaseOld = true
        for _ in 0..<10 { await Task.yield() }
        #expect(panel.results.map(\.name) == [newer.name])
    }

    @Test func switchingToLargeOpenDocumentScopeImmediatelyRemovesUnopenedRows() async throws {
        _ = NSApplication.shared
        let panel = FileNameSearchController(); defer { panel.dismiss() }
        let opened = (0..<501).map { FileNameSearchEntry(name: "open-\($0)", path: "/project/open-\($0)", target: .tab(TabID())) }
        let root = WorkspaceRoot(canonicalPath: "/project", displayName: "project")
        let disk = FileNameSearchEntry(name: "needle", path: "/project/needle", target: .workspace(.init(rootID: root.id,
            relativePath: "needle", name: "needle", kind: .file)))
        panel.onLoadRequest = { _, _ in ([disk], false, 0) }
        panel.present(in: nil, initial: opened); panel.setQuery("needle")
        let deadline = ContinuousClock.now + .seconds(3)
        while panel.results.first?.name != "needle", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(panel.results.first?.name == "needle")
        panel.selectScope(.openDocuments)
        // Check synchronously, before the detached worker can complete.
        #expect(panel.results.isEmpty)
    }

    @Test func profileDirectoryWhenExplicitlyRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["DUCKPAD_FILENAME_PROFILE_ROOT"],
              let helper = ProcessInfo.processInfo.environment["DUCKPAD_FILENAME_PROFILE_RG"] else { return }
        let indexer = LocalFolderFileNameIndex(executable: URL(fileURLWithPath: helper))
        for limit in [20_000] {
            let start = ContinuousClock.now
            let timing = NameProgressTiming(start: start)
            let result = try await indexer.search(in: URL(fileURLWithPath: path), query: "util",
                maximumEntries: limit, includeHiddenFiles: false) { update in await timing.record(update.relativePaths.count) }
            let first = await timing.firstMilliseconds
            let updates = await timing.count
            print("DUCKPAD_FILENAME_PROGRESS first_ms=\(first ?? -1) snapshots=\(updates)")
            let duration = start.duration(to: .now).components
            let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            print("DUCKPAD_FILENAME_PROFILE limit=\(limit) matches=\(result.relativePaths.count) truncated=\(result.isTruncated) ms=\(ms)")
            #expect(!result.relativePaths.isEmpty)
        }
    }
}

private actor GatedNameStore: WorkspaceRootStore {
    let root = WorkspaceRoot(canonicalPath: "/project", displayName: "project")
    private(set) var fullSearchStarted = false
    private var released = false
    func finish() { released = true }
    func loadRoots() async throws(WorkspaceBrowserFailure) -> [WorkspaceRoot] { [root] }
    func addRoot(_ url: URL) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot { throw .io("unused") }
    func removeRoot(_ id: WorkspaceRootID) async throws(WorkspaceBrowserFailure) { }
    func children(rootID: WorkspaceRootID, relativeDirectory: String) async throws(WorkspaceBrowserFailure) -> [WorkspaceBrowserEntry] { [] }
    func readFile(_ entry: WorkspaceBrowserEntry) async throws(WorkspaceBrowserFailure) -> WorkspaceFileRead { throw .io("unused") }
    func updateNavigation(rootID: WorkspaceRootID, expandedRelativePaths: [String], selectedRelativePath: String?) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot { root }
    func fileNameIndex(rootID: WorkspaceRootID, query: String, maximumEntries: Int, includeHiddenFiles: Bool,
                       onProgress: @escaping @Sendable (WorkspaceFileNameIndex) async -> Void) async throws -> WorkspaceFileNameIndex {
        if query == "util" {
            await onProgress(.init(files: [.init(rootID: root.id, relativePath: "util.ts", name: "util.ts", kind: .file)],
                isTruncated: true, skippedDirectoryCount: 0))
        }
        return try await fileNameIndex(rootID: rootID, query: query, maximumEntries: maximumEntries, includeHiddenFiles: includeHiddenFiles)
    }
    func fileNameIndex(rootID: WorkspaceRootID, query: String, maximumEntries: Int, includeHiddenFiles: Bool) async throws -> WorkspaceFileNameIndex {
        guard query == "util" else { return .init(files: [], isTruncated: false, skippedDirectoryCount: 0) }
        if maximumEntries > 100 {
            fullSearchStarted = true
            while !released { try await Task.sleep(for: .milliseconds(5)) }
        }
        return .init(files: [.init(rootID: root.id, relativePath: maximumEntries > 100 ? "util" : "util.ts",
            name: maximumEntries > 100 ? "util" : "util.ts", kind: .file)],
            isTruncated: maximumEntries <= 100, skippedDirectoryCount: 0)
    }
}

private actor NameProgressTiming {
    let start: ContinuousClock.Instant
    private(set) var firstMilliseconds: Double?
    private(set) var count = 0
    init(start: ContinuousClock.Instant) { self.start = start }
    func record(_ names: Int) {
        guard names > 0 else { return }
        if firstMilliseconds == nil {
            let duration = start.duration(to: .now).components
            firstMilliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        }
        count += 1
    }
}
