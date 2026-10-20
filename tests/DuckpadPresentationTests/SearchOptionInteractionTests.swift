import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct SearchOptionInteractionTests {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func button(_ id: String, in panel: MultiFileSearchController) throws -> SearchOptionButton {
        let root = try #require(panel.window?.contentView)
        return try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.multifile." + id } as? SearchOptionButton)
    }
    private func panel(text: String) -> MultiFileSearchController {
        _ = NSApplication.shared
        let panel = MultiFileSearchController()
        let snapshot = SearchBufferSnapshot(tabID: TabID(), title: "Options.swift", bufferID: BufferID(), revision: 0, utf8: Data(text.utf8))
        panel.onSearch = { query, _ in
            let matches = try SearchEngine.matches(in: snapshot, query: query, regexEngine: ICURegexEngine())
            return .open(.init(generation: 0, documents: matches.isEmpty ? [] : [.init(tabID: snapshot.tabID, title: snapshot.title, matches: matches)], isTruncated: false, searchedByteCount: snapshot.utf8.count))
        }
        panel.present(replace: true, in: nil)
        return panel
    }
    private func wait(_ panel: MultiFileSearchController) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while panel.result == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(panel.result != nil)
    }
    @Test func accessibilityPressTogglesCaseAndWordResultsInBothDirections() async throws {
        let panel = panel(text: "duck Duck duckling"); defer { panel.dismiss() }
        panel.setQuery(.init(pattern: "duck")); panel.searchPressed(); try await wait(panel)
        #expect(panel.result?.matchCount == 3)
        let cc = try button("case", in: panel), word = try button("word", in: panel)
        #expect(cc.accessibilityPerformPress()); try await wait(panel)
        #expect(cc.isOn); #expect(panel.currentQuery().options.matchCase)
        #expect(panel.result?.matchCount == 2)
        #expect(word.accessibilityPerformPress()); try await wait(panel)
        #expect(word.isOn); #expect(panel.result?.matchCount == 1)
        #expect(cc.accessibilityPerformPress()); try await wait(panel)
        #expect(!cc.isOn); #expect(panel.result?.matchCount == 2)
        #expect(word.accessibilityPerformPress()); try await wait(panel)
        #expect(!word.isOn); #expect(panel.result?.matchCount == 3)
    }
    @Test func regexAndDotNewlineTogglesUpdateTheRealMatcher() async throws {
        let panel = panel(text: "duck Duck duckling d\nck"); defer { panel.dismiss() }
        panel.setQuery(.init(pattern: "d.ck")); panel.searchPressed(); try await wait(panel)
        #expect(panel.result?.matchCount == 0)
        let regex = try button("regex", in: panel), dot = try button("newline", in: panel)
        regex.performClick(nil); try await wait(panel)
        #expect(regex.isOn); #expect(panel.currentQuery().options.mode == .regularExpression)
        #expect(panel.result?.matchCount == 3)
        dot.performClick(nil); try await wait(panel)
        #expect(dot.isOn); #expect(panel.result?.matchCount == 4)
        regex.performClick(nil); try await wait(panel)
        #expect(!regex.isOn); #expect(panel.result?.matchCount == 0)
    }
    private func pixel(_ button: NSButton) throws -> NSColor {
        let rep = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: rep)
        return try #require(rep.colorAt(x: max(1, rep.pixelsWide / 10), y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }
    @Test func selectedOptionHasPersistentTintAndAccessibleOnOffState() throws {
        let panel = panel(text: "duck Duck"); defer { panel.dismiss() }
        let cc = try button("case", in: panel)
        cc.performClick(nil)
        #expect(cc.isOn)
        let on = try pixel(cc)
        #expect((cc.accessibilityValue() as? NSNumber)?.boolValue == true)
        cc.performClick(nil)
        #expect(!cc.isOn)
        let off = try pixel(cc)
        #expect(abs(on.redComponent - off.redComponent) + abs(on.greenComponent - off.greenComponent) + abs(on.blueComponent - off.blueComponent) + abs(on.alphaComponent - off.alphaComponent) > 0.2)
        #expect((cc.accessibilityValue() as? NSNumber)?.boolValue == false)
    }
}
