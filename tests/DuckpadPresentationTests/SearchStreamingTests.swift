import AppKit
import DuckpadDomain
import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct SearchStreamingTests {
    private func result(_ title: String, count: Int = 1, incomplete: Bool = false) -> MultiFileSearchResults {
        let tab = TabID(), buffer = BufferID()
        return .open(.init(generation: 0, documents: [.init(tabID: tab, title: title, matches: (0..<count).map {
            .init(tabID: tab, bufferID: buffer, revision: 0, range: .init(location: $0 * 4, length: 4), line: $0 + 1, column: 1, snippet: title)
        })], isTruncated: incomplete, searchedByteCount: count * 4))
    }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(predicate())
    }
    @Test func partialResultsStayVisibleButCannotReplaceAndLateProgressCannotOverwriteCompletion() async throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); panel.present(replace: true, in: nil)
        var finish = false
        var progress: MultiFileSearchController.Progress?
        panel.onSearchWithProgress = { _, _, receive in
            progress = receive; receive(result("partial", count: 3, incomplete: true))
            while !finish { await Task.yield() }
            return result("complete", count: 4)
        }
        defer { finish = true; panel.dismiss() }
        panel.setQuery(.init(pattern: "test")); panel.searchPressed()
        try await wait { panel.rows.count == 3 }
        let root = try #require(panel.window?.contentView)
        let apply = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.apply" } as? NSButton)
        #expect(!apply.isEnabled)
        let table = try #require(views(root).first { $0 is SearchResultTableView } as? NSTableView)
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        finish = true
        try await wait { apply.isEnabled }
        #expect(panel.rows.first?.title == "complete")
        #expect(table.selectedRow == 2)
        progress?(result("late", incomplete: true))
        #expect(panel.rows.first?.title == "complete")
        #expect(apply.isEnabled)
    }
    @Test func completedTruncatedResultsRemainVisibleWithoutEnablingReplacement() async throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); panel.present(replace: true, in: nil)
        defer { panel.dismiss() }
        panel.onSearch = { _, _ in result("bounded", incomplete: true) }
        panel.setQuery(.init(pattern: "test")); panel.searchPressed()
        let root = try #require(panel.window?.contentView)
        let open = try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile.openResults" } as? NSButton)
        try await wait { open.isEnabled }
        #expect(panel.rows.first?.title == "bounded")
        for identifier in ["duckpad.multifile.apply", "duckpad.multifile.replaceOne"] {
            let button = try #require(views(root).first { $0.accessibilityIdentifier() == identifier } as? NSButton)
            #expect(!button.isEnabled)
        }
    }
    @Test func restartingTheSameQueryRejectsOldProgressAndClosingRejectsAllProgress() async throws {
        let panel = MultiFileSearchController()
        var callbacks: [MultiFileSearchController.Progress] = []
        var finish = false
        panel.onSearchWithProgress = { _, _, progress in
            callbacks.append(progress)
            while !finish { await Task.yield() }
            return result("final")
        }
        defer { finish = true; panel.dismiss() }
        panel.setQuery(.init(pattern: "same")); panel.searchPressed()
        try await wait { callbacks.count == 1 }
        panel.searchPressed()
        try await wait { callbacks.count == 2 }
        callbacks[1](result("current", incomplete: true))
        callbacks[0](result("stale", incomplete: true))
        #expect(panel.rows.first?.title == "current")
        panel.dismiss()
        callbacks[1](result("after-close", incomplete: true))
        #expect(panel.rows.first?.title != "after-close")
    }
    @Test func progressCoalescesWhileMainActorIsBusyAndDisplayCapKeepsAllReplacementMatches() async throws {
        var received: [Int] = []
        let delivery = SearchProgressDelivery { received.append($0.matchCount) }
        for index in 1...1000 { delivery.offer(result("queued", count: index)) }
        #expect(received.isEmpty)
        try await wait { !received.isEmpty }
        #expect(received == [1000])
        let full = result("all", count: 6000)
        #expect(full.rows(catalog: .init(language: .english)).count == 5000)
        #expect(full.matchCount == 6000)
        #expect(full.openMatches.count == 6000)
        #expect(!full.isTruncated)
    }
}
