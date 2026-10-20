import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct FileNameSearchDesignTests {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func element<T: NSView>(_ id: String, in panel: FileNameSearchController, as type: T.Type) throws -> T {
        let root = try #require(panel.window?.contentView)
        return try #require(views(root).first { $0.accessibilityIdentifier() == "duckpad.files." + id } as? T)
    }
    private func entries() -> [FileNameSearchEntry] {
        [.init(name: "main.swift", path: "/Duckpad/Sources/main.swift", target: .tab(TabID()), project: "Duckpad"),
         .init(name: "main.rs", path: "/Duckpad/native/src/main.rs", target: .workspace(.init(rootID: WorkspaceRootID(), relativePath: "native/src/main.rs", name: "main.rs", kind: .file)), project: "Duckpad")]
    }
    @Test func filenameTabsFilterOpenDocumentsAndRestoreAllFiles() throws {
        _ = NSApplication.shared
        let panel = FileNameSearchController(); panel.present(in: nil, initial: entries())
        defer { panel.dismiss() }
        let scopes = try element("scope", in: panel, as: NSStackView.self)
        let tabs = scopes.arrangedSubviews.compactMap { $0 as? SearchOptionButton }
        #expect(tabs.count == 4); #expect(tabs.map(\.isOn) == [true, false, false, false])
        #expect(tabs.allSatisfy { $0.intrinsicContentSize.height == 28 })
        #expect(!tabs[2].isEnabled); #expect(!tabs[2].accessibilityPerformPress())
        tabs[1].performClick(nil)
        #expect(panel.selectedScope == .openDocuments)
        #expect(panel.results.map(\.name) == ["main.swift"])
        tabs[1].performClick(nil); #expect(tabs[1].isOn)
        tabs[0].performClick(nil); #expect(panel.selectedScope == .all)
        #expect(panel.results.count == 2)

    }
    @Test func selectionTracksFullPathAndSplitOpensOnlyTheChosenFile() throws {
        _ = NSApplication.shared
        let panel = FileNameSearchController()
        var normal: FileNameSearchEntry?, split: FileNameSearchEntry?
        panel.onOpen = { normal = $0 }; panel.onOpenInSplit = { split = $0 }
        panel.present(in: nil, initial: entries()); defer { panel.dismiss() }
        let table = try element("results", in: panel, as: NSTableView.self)
        let path = try element("path", in: panel, as: NSTextField.self)
        #expect(table.rowHeight == 28); #expect(path.stringValue == "/Duckpad/Sources/main.swift")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(path.stringValue == "/Duckpad/native/src/main.rs")
        let button = try element("split", in: panel, as: NSButton.self)
        #expect(!button.isHidden && button.isEnabled)
        _ = NSApp.sendAction(try #require(button.action), to: button.target, from: button)
        #expect(split?.name == "main.rs"); #expect(normal == nil); #expect(panel.window?.isVisible == false)
    }
    @Test func filenameRowsKeepIconHighlightedNameAndDirectoryOnOneLine() throws {
        _ = NSApplication.shared
        let cell = SearchResultCell(frame: .init(x: 0, y: 0, width: 700, height: 28))
        cell.apply(title: "main.swift", detail: "/Duckpad/Sources/main.swift", project: "Duckpad", query: "MAIN")
        cell.layoutSubtreeIfNeeded()
        let title = try #require(cell.textField), icon = try #require(cell.imageView)
        #expect(icon.image != nil); #expect(title.stringValue == "main.swift")
        #expect(title.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        #expect(title.attributedStringValue.attribute(.backgroundColor, at: 5, effectiveRange: nil) == nil)
        let labels = cell.subviews.compactMap { $0 as? NSTextField }
        #expect(labels.map(\.stringValue).contains("/Duckpad/Sources"))
        #expect(labels.map(\.stringValue).contains("Duckpad"))
        #expect(labels.allSatisfy { abs($0.frame.midY - cell.bounds.midY) <= 0.5 })
        #expect(icon.frame.maxX + 8 <= title.frame.minX)
    }
    @Test func filenameReferenceSnapshotsShowDenseResultsAndSplitFooter() throws {
        guard let directory = ProcessInfo.processInfo.environment["DUCKPAD_SEARCH_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        let panel = FileNameSearchController(); panel.onOpenInSplit = { _ in }
        panel.configureWorkspace([.init(canonicalPath: "/Duckpad", displayName: "Duckpad")])
        let names = ["main.swift", "main.rs", "main_test.swift", "main-view-controller.swift", "main.py", "main.proto", "main.yml", "main.md", "main.json", "main.h", "main.c", "main.rb"]
        panel.present(in: nil, initial: names.map { .init(name: $0, path: "/Duckpad/Sources/Editor/" + $0, target: .tab(TabID()), project: "Duckpad") })
        panel.setQuery("main"); defer { panel.dismiss() }
        let window = try #require(panel.window)
        for language in AppLanguage.allCases where language != .system {
            panel.refreshLocalization(catalog: .init(language: language))
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                window.appearance = NSAppearance(named: appearance)
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), URL(fileURLWithPath: directory).appendingPathComponent("filename-reference-" + language.rawValue + "-" + appearance.rawValue + ".png").path]
                try capture.run(); capture.waitUntilExit(); #expect(capture.terminationStatus == 0)
            }
        }
    }
    @Test func filenameChromeFitsEveryLocaleAtMinimumWidth() throws {
        _ = NSApplication.shared
        let panel = FileNameSearchController(); panel.onOpenInSplit = { _ in }
        panel.present(in: nil, initial: entries()); defer { panel.dismiss() }
        let window = try #require(panel.window)
        window.setContentSize(.init(width: 520, height: 320))
        for language in AppLanguage.allCases where language != .system {
            panel.refreshLocalization(catalog: .init(language: language))
            window.contentView?.layoutSubtreeIfNeeded()
            panel.configureWorkspace([.init(canonicalPath: "/Duckpad", displayName: "Duckpad")])
            panel.selectFolder(URL(fileURLWithPath: "/Duckpad/" + String(repeating: "long-directory/", count: 20)))
            let query = try element("query", in: panel, as: NSTextField.self)
            #expect(query.frame.width > 250)
            window.contentView?.layoutSubtreeIfNeeded()
            let scopes = try element("scope", in: panel, as: NSStackView.self)
            let controls = scopes.arrangedSubviews + [try element("split", in: panel, as: NSButton.self)]
            for control in controls {
                #expect(control.frame.width >= control.intrinsicContentSize.width - 1)
                let rect = control.convert(control.bounds, to: window.contentView)
                #expect(rect.minX >= 0 && rect.maxX <= 520)
            }
        }
    }
}
