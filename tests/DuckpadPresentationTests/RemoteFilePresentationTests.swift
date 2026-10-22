import AppKit
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadApplication
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@MainActor private final class BrowserFixture: RemoteFileBrowsing {
    var readLimits = [Int]()
    var readSources = [FileObservationSource]()
    var directoryAttempts = 0, directoryFailures = 0
    var directoryError = FileObservationError.unavailable
    var directoryPaths = [String?]()
    var slowEntered = false, slowCompleted = false
    var slowGate: CheckedContinuation<Void, Never>?
    func releaseSlow() { slowGate?.resume(); slowGate = nil }
    func configuredHosts() async throws -> [String] { ["fixture", "second"] }
    func directory(host: String, path: String?) async throws -> RemoteDirectoryListing {
        directoryAttempts += 1
        directoryPaths.append(path)
        if directoryFailures > 0 { directoryFailures -= 1; throw directoryError }
        if path == "/missing" || path == "/file.log" { throw FileObservationError.directoryUnavailable }
        if path == "/slow" {
            slowEntered = true
            await withCheckedContinuation { slowGate = $0 }
            slowCompleted = true
        }
        return .init(path: path ?? "/logs", entries: [.init(name: ".hidden", isDirectory: false),
            .init(name: "folder", isDirectory: true), .init(name: "a.log", isDirectory: false), .init(name: "b.log", isDirectory: false)])
    }
    func read(_ source: FileObservationSource, after cursor: FileObservationCursor?, maximumBytes: Int) async throws -> FileObservationRead {
        readLimits.append(maximumBytes)
        readSources.append(source)
        let data = Data("INFO 한글 🦆\n".utf8)
        return .init(data: data, cursor: .init(identity: "1:2", offset: UInt64(data.count)), sourceSize: UInt64(data.count), reset: false)
    }
}

@Suite(.serialized) @MainActor struct RemoteFilePresentationTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
    @Test func inaccessibleHomeStillAllowsExplicitDirectoryOnFirstConnect() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let presenter = RemoteFilePanel(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            retryPolicy: .init(delays: [.zero, .zero, .zero]))
        let browser = BrowserFixture()
        browser.directoryFailures = 1; browser.directoryError = .directoryUnavailable
        defer { presenter.dismiss(); window.close() }
        presenter.refreshLocalization(catalog: .init(language: .english))
        presenter.show(attachedTo: window, browser: browser, showHiddenFiles: false) { _, _ in }
        presenter.host.stringValue = "fixture"; presenter.path.stringValue = "/var/log"
        _ = presenter.host.sendAction(presenter.host.action!, to: presenter.host.target)
        try await wait { presenter.listing?.path == "/var/log" }
        #expect(browser.directoryPaths.count == 2)
        #expect(browser.directoryPaths[0] == nil && browser.directoryPaths[1] == "/var/log")
        #expect(presenter.path.stringValue == "/var/log")
        #expect(presenter.status.stringValue.contains("Connected · SSH connection shared"))
    }
    @Test func retainedListingSelectionAndEditedPathOpenTheirExplicitTargets() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let presenter = RemoteFilePanel(defaults: UserDefaults(suiteName: UUID().uuidString)!), browser = BrowserFixture()
        var opened = [RemoteFileLocation]()
        defer { presenter.dismiss(); window.close() }
        presenter.refreshLocalization(catalog: .init(language: .english))
        presenter.show(attachedTo: window, browser: browser, showHiddenFiles: false) { files, _ in opened += files }
        presenter.host.stringValue = "fixture"; presenter.path.stringValue = "/missing"
        _ = presenter.host.sendAction(presenter.host.action!, to: presenter.host.target)
        try await wait { presenter.status.stringValue.contains("Connected · Folder unavailable") }
        presenter.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await wait { presenter.preview.string.contains("INFO") }
        let selected = try #require(RemoteFileLocation(host: "fixture", path: "/logs/a.log"))
        #expect(browser.readSources.last == .ssh(selected))
        presenter.open.performClick(nil)
        try await wait { opened == [selected] }
        presenter.path.stringValue = "/direct.log"
        presenter.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: presenter.path))
        #expect(presenter.table.selectedRow == -1)
        #expect(!presenter.preview.string.contains("INFO"))
        presenter.open.performClick(nil)
        try await wait { opened.count == 2 }
        #expect(opened.last?.path == "/direct.log")
    }
    @Test(arguments: ["/missing", "/file.log", "relative-path"])
    func connectSucceedsBeforeReportingBadPathsWithoutReconnects(path: String) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let presenter = RemoteFilePanel(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            retryPolicy: .init(delays: [.zero, .zero, .zero]))
        let browser = BrowserFixture()
        defer { presenter.dismiss(); window.close() }
        presenter.refreshLocalization(catalog: .init(language: .english))
        presenter.show(attachedTo: window, browser: browser, showHiddenFiles: false) { _, _ in }
        presenter.host.stringValue = "fixture"; presenter.path.stringValue = path
        _ = presenter.host.sendAction(presenter.host.action!, to: presenter.host.target)
        try await wait { presenter.status.stringValue.contains("Connected · Folder unavailable") }
        #expect(presenter.listing?.path == "/logs")
        #expect(presenter.path.stringValue == path)
        #expect(presenter.recentHosts == ["fixture"])
        #expect(browser.directoryPaths[0] == nil)
        #expect(browser.directoryPaths.compactMap { $0 } == (path.hasPrefix("/") ? [path] : []))
        presenter.path.stringValue = "/good"
        _ = presenter.path.sendAction(presenter.path.action!, to: presenter.path.target)
        try await wait { presenter.listing?.path == "/good" }
        #expect(browser.directoryPaths.filter { $0 == nil }.count == 1)
        #expect(browser.directoryPaths.last == "/good")
        #expect(!presenter.status.stringValue.contains("Retry"))
    }
    @Test func browserFitsLocalizedControlsAndClosesWithoutOpening() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let defaults = UserDefaults(suiteName: "duckpad-browser-test-" + UUID().uuidString)!
        let presenter = RemoteFilePanel(defaults: defaults), browser = BrowserFixture()
        var opens = 0
        for language in AppLanguage.allCases where language != .system {
            presenter.refreshLocalization(catalog: .init(language: language))
            presenter.host.stringValue = ""; presenter.path.stringValue = ""
            presenter.show(attachedTo: window, browser: browser, showHiddenFiles: false) { _, _ in opens += 1 }
            let panel = try #require(presenter.panel), root = try #require(panel.contentView)
            panel.setContentSize(.init(width: 720, height: 560)); root.layoutSubtreeIfNeeded()
            #expect(!presenter.open.isEnabled)
            #expect(presenter.host.input.isEnabled && presenter.path.input.isEnabled)
            presenter.host.stringValue = "user@alias"; presenter.path.stringValue = "/var/log/app.log"
            presenter.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: presenter.path))
            #expect(presenter.open.isEnabled)
            for control in [presenter.host, presenter.path, presenter.open, presenter.tail] {
                let frame = control.convert(control.bounds, to: root)
                #expect(frame.minX >= -1 && frame.maxX <= root.bounds.width + 1)
                #expect(frame.minY >= -1 && frame.maxY <= root.bounds.height + 1)
                #expect(control.frame.width >= control.intrinsicContentSize.width - 1 || control is NSTextField)
            }
            presenter.dismiss()
            #expect(presenter.panel == nil && opens == 0)
        }
    }
    @Test func browserReusesConnectionContextForPreviewAndMultipleOpenAndIgnoresCancelledNavigation() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let presenter = RemoteFilePanel(defaults: UserDefaults(suiteName: "duckpad-browser-test-" + UUID().uuidString)!)
        let browser = BrowserFixture(); var opened = [RemoteFileLocation]()
        presenter.show(attachedTo: window, browser: browser, showHiddenFiles: false) { files, _ in opened += files }
        defer { browser.releaseSlow(); presenter.dismiss() }
        presenter.host.stringValue = "fixture"
        _ = presenter.host.sendAction(presenter.host.action!, to: presenter.host.target)
        try await wait { presenter.listing != nil }
        #expect(presenter.table.numberOfRows == 3)
        presenter.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await wait { !browser.readLimits.isEmpty }
        #expect(browser.readLimits.allSatisfy { $0 == 16 * 1_024 })
        #expect(presenter.preview.string.contains("한글"))
        presenter.table.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)
        presenter.open.performClick(nil)
        try await wait { opened.count == 2 }
        #expect(opened.map(\.path) == ["/logs/a.log", "/logs/b.log"])
        #expect(presenter.panel != nil)
        presenter.path.stringValue = "/slow"
        _ = presenter.path.sendAction(presenter.path.action!, to: presenter.path.target)
        try await wait { browser.slowEntered }
        presenter.path.stringValue = "/typing"
        presenter.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: presenter.path))
        browser.releaseSlow()
        try await wait { browser.slowCompleted }
        for _ in 0..<10 { await Task.yield() }
        #expect(presenter.path.stringValue == "/typing" && presenter.listing?.path == "/logs")
        presenter.path.stringValue = "/fast"
        _ = presenter.path.sendAction(presenter.path.action!, to: presenter.path.target)
        try await wait { presenter.listing?.path == "/fast" }
        try await Task.sleep(for: .milliseconds(150))
        #expect(presenter.listing?.path == "/fast")
        #expect(presenter.recentHosts == ["fixture"])
    }

    @Test func connectionRetriesAreBoundedAndManualRetryAndCancellationWork() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let presenter = RemoteFilePanel(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            retryPolicy: .init(delays: [.milliseconds(10), .milliseconds(10), .milliseconds(10)]))
        let browser = BrowserFixture(); browser.directoryFailures = 2
        presenter.show(attachedTo: window, browser: browser, showHiddenFiles: false) { _, _ in }
        defer { presenter.dismiss() }
        presenter.host.stringValue = "fixture"
        _ = presenter.host.sendAction(presenter.host.action!, to: presenter.host.target)
        try await wait { presenter.listing != nil }
        #expect(browser.directoryAttempts == 3)
        #expect(presenter.path.filteredSuggestions == ["/logs/folder"])
        presenter.host.stringValue = "second"
        presenter.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: presenter.host))
        #expect(presenter.path.filteredSuggestions.isEmpty)
        browser.directoryFailures = 10
        _ = presenter.host.sendAction(presenter.host.action!, to: presenter.host.target)
        try await wait { browser.directoryAttempts == 7 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(browser.directoryAttempts == 7 && presenter.status.stringValue.contains("Retry"))
        browser.directoryFailures = 0
        _ = presenter.host.sendAction(presenter.host.action!, to: presenter.host.target)
        try await wait { presenter.listing != nil }
        #expect(browser.directoryAttempts == 8)
        browser.directoryFailures = 10
        _ = presenter.host.sendAction(presenter.host.action!, to: presenter.host.target)
        try await wait { browser.directoryAttempts == 9 }
        presenter.cancelOperations()
        try await Task.sleep(for: .milliseconds(80))
        #expect(browser.directoryAttempts == 9)
        browser.directoryError = .invalidResponse
        _ = presenter.host.sendAction(presenter.host.action!, to: presenter.host.target)
        try await wait { browser.directoryAttempts == 10 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(browser.directoryAttempts == 10)
    }

    @Test func remoteOpenShortcutIsUniqueAndCanBeRemapped() throws {
        _ = NSApplication.shared
        let controller = DuckpadWindowController(workspace: ScratchWorkspaceUseCase(store: InMemorySessionStore()),
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), automaticallyStarts: false)
        defer { controller.close() }
        let registry = ShortcutRegistry(menu: DuckpadMainMenuFactory.make(target: controller), overrides: [:])
        let remoteID = "performOpenRemoteFile:"
        let remote = try #require(registry.entries.first { $0.id == remoteID })
        #expect(remote.displayShortcut == "⌃⌘O")
        #expect(registry.entries.filter { !$0.identities.isDisjoint(with: remote.identities) }.map(\.id) == [remoteID])
        #expect(registry.conflict(for: "cmd+shift+o", excluding: remoteID)?.id == "performShowDocumentSwitcher:")
        #expect(registry.conflict(for: "cmd+alt+o", excluding: remoteID)?.id == "performShowDocumentSymbols:")
        let remapped = ShortcutRegistry(menu: DuckpadMainMenuFactory.make(target: controller), overrides: [remoteID: "cmd+alt+shift+o"])
        #expect(remapped.entries.first { $0.id == remoteID }?.displayShortcut == "⌥⇧⌘O")
        #expect(remapped.conflict(for: "ctrl+cmd+o", excluding: "other") == nil)
    }

    @Test func browserShortcutsStayInTheBrowserAndCloseWithoutOpeningFiles() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let presenter = RemoteFilePanel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let browser = BrowserFixture(); var opens = 0
        presenter.show(attachedTo: window, browser: browser, showHiddenFiles: false) { _, _ in opens += 1 }
        defer { presenter.dismiss() }
        let panel = try #require(presenter.panel)
        func key(_ code: UInt16, _ text: String, _ modifiers: NSEvent.ModifierFlags = [.command]) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            return panel.performKeyEquivalent(with: event)
        }
        #expect(try key(37, "l"))
        #expect(panel.firstResponder === presenter.path.input.currentEditor())
        #expect(try key(37, "L", [.command, .shift]))
        #expect(panel.firstResponder === presenter.host.input.currentEditor())
        // A disabled refresh is consumed here rather than opening editor Replace.
        #expect(try key(15, "r")); #expect(browser.directoryAttempts == 0)
        presenter.host.stringValue = "fixture"; presenter.path.stringValue = "/logs"
        presenter.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: presenter.host))
        #expect(try key(15, "r"))
        try await wait { presenter.listing?.path == "/logs" }
        #expect(try key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        try await wait { presenter.listing?.path == "/" }
        #expect(try key(37, "ㅣ")) // ASCII-capable layout normalization while Korean is selected.
        #expect(panel.firstResponder === presenter.path.input.currentEditor())
        #expect(try key(13, "w"))
        #expect(presenter.panel == nil && opens == 0)
    }

    @Test func appEventsRefreshAndCloseRemoteWindowWithoutReplacingOrClosingEditor() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
            markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view,
            searchUseCase: search, automaticallyStarts: false)
        let oldMenu = NSApp.mainMenu
        let presenter = RemoteFilePanel(defaults: UserDefaults(suiteName: UUID().uuidString)!), browser = BrowserFixture()
        defer { presenter.dismiss(); NSApp.mainMenu = oldMenu; controller.close(); editor.invalidate() }
        controller.start(); await controller.waitForStartup()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        NSApp.mainMenu = DuckpadMainMenuFactory.make(target: controller)
        let before = workspace.snapshot().tabs
        presenter.show(attachedTo: try #require(controller.window), browser: browser, showHiddenFiles: false) { _, _ in }
        let panel = try #require(presenter.panel)
        presenter.host.stringValue = "fixture"; presenter.path.stringValue = "/logs"
        presenter.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: presenter.host))
        presenter.path.focus(); presenter.host.dismissSuggestions(); presenter.path.dismissSuggestions()
        func send(_ code: UInt16, _ text: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
        }
        try send(15, "ㄱ")
        try await wait { browser.directoryAttempts == 1 }
        #expect(controller.searchPanel.isHidden && workspace.snapshot().tabs == before)
        try send(13, "ㅈ")
        #expect(presenter.panel == nil && workspace.snapshot().tabs == before)
        #expect(controller.window?.isVisible == true)
    }

    @Test func nativeBrowserThemeSnapshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["DUCKPAD_REMOTE_THEME_SNAPSHOTS"] else { return }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let presenter = RemoteFilePanel(defaults: UserDefaults(suiteName: UUID().uuidString)!), browser = BrowserFixture()
        presenter.show(attachedTo: window, browser: browser, showHiddenFiles: false) { _, _ in }
        defer { presenter.dismiss() }
        presenter.host.stringValue = "fixture"
        _ = presenter.host.sendAction(presenter.host.action!, to: presenter.host.target)
        try await wait { presenter.listing != nil }
        presenter.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await wait { presenter.preview.string.contains("한글") }
        let panel = try #require(presenter.panel), root = try #require(panel.contentView)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: appearance)
            presenter.host.dismissSuggestions(); presenter.path.dismissSuggestions()
            root.layoutSubtreeIfNeeded(); panel.displayIfNeeded()
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let destination = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("remote-\(appearance.rawValue).png"))
        }
    }

    @Test func tailBarKeepsControlsWithinMinimumWindowWidthInEveryLanguage() throws {
        _ = NSApplication.shared
        let bar = TailStatusBar(frame: .zero)
        let host = NSView(frame: .init(x: 0, y: 0, width: 420, height: 28))
        host.addSubview(bar)
        NSLayoutConstraint.activate([bar.leadingAnchor.constraint(equalTo: host.leadingAnchor), bar.trailingAnchor.constraint(equalTo: host.trailingAnchor), bar.topAnchor.constraint(equalTo: host.topAnchor)])
        for language in AppLanguage.allCases where language != .system {
            let catalog = LocalizationCatalog(language: language)
            bar.refreshLocalization(catalog: catalog)
            bar.show(catalog.text("Tail · Scrolling paused"))
            host.layoutSubtreeIfNeeded()
            #expect(bar.frame.height == 28)
            for button in [bar.follow, bar.clear, bar.stop] {
                let frame = button.convert(button.bounds, to: bar)
                #expect(frame.minX >= 0 && frame.maxX <= 420)
                #expect(button.accessibilityLabel()?.isEmpty == false)
            }
        }
        bar.show("Connection unavailable", warning: true, canRetry: true)
        host.layoutSubtreeIfNeeded()
        #expect(!bar.retry.isHidden && bar.retry.accessibilityLabel()?.isEmpty == false)
        #expect(bar.retry.convert(bar.retry.bounds, to: bar).maxX <= 420)
        bar.show(nil)
        #expect(bar.retry.isHidden)
        host.layoutSubtreeIfNeeded()
        #expect(bar.isHidden && bar.frame.height == 0)
    }
}
