import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadScintillaBridge
@testable import DuckpadPresentation
import Testing

private actor CountingDeclarationAnalyzer: DeclarationAnalyzing {
    private(set) var count = 0
    func index(utf8: Data, language: String) async -> DeclarationIndex {
        count += 1
        return await BuiltinDeclarationAnalyzer().index(utf8: utf8, language: language)
    }
}

private actor CountingProjectLookup: DeclarationProjectSearching {
    private(set) var count = 0
    func find(name: String, language: String, kind: SymbolNavigationKind, roots: [WorkspaceRoot], excludingPaths: Set<String>) async -> DeclarationProjectResult {
        count += 1
        return .init(matches: [.init(url: URL(fileURLWithPath: "/tmp/duckpad-navigation-test/defs.swift"), utf8: Data("func swim() {}".utf8), match: .init(name: "swim", range: .init(location: 5, length: 4), line: 1))], isComplete: true)
    }
}

private actor PausingProjectLookup: DeclarationProjectSearching {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func release() { continuation?.resume(); continuation = nil }
    func find(name: String, language: String, kind: SymbolNavigationKind, roots: [WorkspaceRoot], excludingPaths: Set<String>) async -> DeclarationProjectResult {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return .init(matches: [.init(url: URL(fileURLWithPath: "/tmp/duckpad-navigation-test/defs.swift"), utf8: Data("func swim() {}".utf8), match: .init(name: "swim", range: .init(location: 5, length: 4), line: 1))], isComplete: true)
    }
}

private actor PausingDeclarationAnalyzer: DeclarationAnalyzing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func release() { released = true; continuation?.resume(); continuation = nil }
    func index(utf8: Data, language: String) async -> DeclarationIndex {
        if !released { await withCheckedContinuation { continuation = $0 } }
        return await BuiltinDeclarationAnalyzer().index(utf8: utf8, language: language)
    }
}

private actor NavigationSessionStore: SessionStore {
    private let store = InMemorySessionStore()
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() { paused = true }
    func resume() { paused = false; continuation?.resume(); continuation = nil }
    func loadSession() async throws(SessionStoreError) -> StoredSession? { try await store.loadSession() }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        if paused { await withCheckedContinuation { continuation = $0 } }
        return try await store.commitSession(session, generation: generation)
    }
}

@Suite(.serialized) @MainActor
struct DeclarationNavigationTests {
    init() { _ = NSApplication.shared; ScintillaEditorAdapter.prepareResources() }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
    @Test(arguments: [false, true])
    func delayedExternalLookupRejectsChangedSource(languageChange: Bool) async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = ScintillaEditorAdapter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        defer { editor.invalidate(); window.close() }
        let buffer = try #require(workspace.snapshot().activeBuffer)
        editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: "swim()")); editor.display(buffer)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        window.makeKeyAndOrderFront(nil); editor.focus()
        let view = try #require(editor.activeScintillaView)
        view.setPrimarySelectionUTF8Range(.init(location: 1, length: 0))
        let capture = try #require(editor.captureDocumentIntelligence(maximumBytes: 1024))
        let project = PausingProjectLookup()
        let root = WorkspaceRoot(canonicalPath: "/tmp/duckpad-navigation-test", displayName: "Test")
        var openCount = 0
        let controller = DeclarationNavigationController(workspace: workspace, editor: editor, project: project, anchor: editor.view, roots: { [root] }, actionable: { true }, open: { _ in openCount += 1; return false })
        defer { controller.cancel() }
        controller.goToDeclaration()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !project.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await project.entered)
        if languageChange {
            _ = editor.applyLanguage(.init(languageID: .init(rawValue: "python"), lexerName: "python", indentation: .init(), folding: false, braceMatching: false))
        } else {
            try view.loadUTF8(Data("duck()".utf8), revision: 0)
            view.setPrimarySelectionUTF8Range(.init(location: 1, length: 0))
        }
        #expect(!editor.declarationContextIsCurrent(capture))
        await project.release()
        try await Task.sleep(for: .milliseconds(80))
        #expect(!controller.panel.isShown && !controller.canGoBack)
        #expect(openCount == 0)
    }

    @Test func hoverSharesProjectLookupAndOtherTabChangesInvalidateIt() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let first = try #require(workspace.snapshot().activeBuffer)
        let firstTab = try #require(workspace.snapshot().tabs.first?.id)
        let editor = ScintillaEditorAdapter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        defer { editor.invalidate(); window.close() }
        editor.install(.init(bufferID: first.bufferID, revision: 0, text: "swim()")); editor.display(first)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        _ = await workspace.addScratch()
        let second = try #require(workspace.snapshot().activeBuffer)
        editor.install(.init(bufferID: second.bufferID, revision: 0, text: "// unsaved")); editor.display(second)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        _ = await workspace.activate(tabID: firstTab); editor.display(first)
        window.makeKeyAndOrderFront(nil); editor.focus()
        let capture = try #require(editor.captureDocumentIntelligence(maximumBytes: 1024))
        let index = await BuiltinDeclarationAnalyzer().index(utf8: capture.utf8, language: "swift")
        let project = CountingProjectLookup()
        let root = WorkspaceRoot(canonicalPath: "/tmp/duckpad-navigation-test", displayName: "Test")
        let controller = DeclarationNavigationController(workspace: workspace, editor: editor, project: project, anchor: editor.view, roots: { [root] }, actionable: { true }, open: { _ in false })
        defer { controller.cancel() }
        #expect(await controller.resolveHover(capture, at: 1, index: index))
        #expect(await project.count == 1)
        controller.goToDeclaration(at: 1)
        try await waitUntil { controller.panel.isShown }
        #expect(await project.count == 1)
        #expect(controller.panel.numberOfRows(in: NSTableView()) == 1)
        editor.install(.init(bufferID: second.bufferID, revision: 0, text: "func swim() {}"))
        #expect(editor.declarationContent(for: first, maximumBytes: 1024) == Data("swim()".utf8))
        #expect(editor.declarationContent(for: second, maximumBytes: 1024) == Data("func swim() {}".utf8))
        controller.workspaceChanged(.init(snapshot: workspace.snapshot(), kind: .bufferEdited(index: 1)))
        controller.goToDeclaration(at: 1)
        try await waitUntil { controller.panel.isShown && controller.panel.numberOfRows(in: NSTableView()) == 2 }
        #expect(await project.count == 2)
        #expect(controller.panel.numberOfRows(in: NSTableView()) == 2)
    }
    @Test(arguments: [false, true])
    func hoverAndClickShareTargetsButRejectReloadedSource(reload: Bool) async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let buffer = try #require(workspace.snapshot().activeBuffer)
        let text = "func swim() {}\nswim()"
        editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: text)); editor.display(buffer)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        let view = try #require(editor.activeScintillaView)
        view.setPrimarySelectionUTF8Range(.init(location: 16, length: 0))
        let capture = try #require(editor.captureDocumentIntelligence(maximumBytes: 1024))
        let index = await BuiltinDeclarationAnalyzer().index(utf8: capture.utf8, language: "swift")
        let analyzer = CountingDeclarationAnalyzer()
        let controller = DeclarationNavigationController(workspace: workspace, editor: editor, project: nil, analyzer: analyzer, anchor: editor.view, roots: { [] }, actionable: { true }, open: { _ in false })
        defer { controller.cancel() }
        #expect(await controller.resolveHover(capture, at: 16, index: index))
        if reload {
            try view.loadUTF8(Data("func duck() {}\nswim()".utf8), revision: 0)
            view.setPrimarySelectionUTF8Range(.init(location: 16, length: 0))
        }
        controller.goToDeclaration(at: 16)
        if reload {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await analyzer.count == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try await Task.sleep(for: .milliseconds(30))
            #expect(await analyzer.count == 1)
            #expect(!controller.canGoBack)
            #expect(view.caretUTF8Position == 16)
        } else {
            try await waitUntil { controller.canGoBack }
            #expect(await analyzer.count == 0)
            #expect(view.anchorUTF8Position == 5 && view.caretUTF8Position == 9)
        }
    }

    @Test func referencesIncludeUnsavedTabsAndNavigateWithHistory() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = ScintillaEditorAdapter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        defer { editor.invalidate(); window.close() }
        let first = try #require(workspace.snapshot().activeBuffer)
        editor.install(.init(bufferID: first.bufferID, revision: 0, text: "func swim() {}\nswim()")); editor.display(first)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        _ = await workspace.addScratch()
        let second = try #require(workspace.snapshot().activeBuffer)
        editor.install(.init(bufferID: second.bufferID, revision: 0, text: "swim()\n// swim\n\"swim\"")); editor.display(second)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        window.makeKeyAndOrderFront(nil); editor.focus()
        editor.activeScintillaView?.setPrimarySelectionUTF8Range(.init(location: 1, length: 0))
        let controller = DeclarationNavigationController(workspace: workspace, editor: editor, project: nil, anchor: editor.view, roots: { [] }, actionable: { true }, open: { _ in false })
        defer { controller.cancel() }
        workspace.onChange = { change in
            if let buffer = change.snapshot.activeBuffer { editor.display(buffer) }
            controller.workspaceChanged(change)
        }
        controller.findReferences()
        try await waitUntil { controller.panel.isShown }
        #expect(controller.panel.numberOfRows(in: NSTableView()) == 2)
        let cell = try #require(controller.panel.tableView(NSTableView(), viewFor: nil, row: 1) as? NSTableCellView)
        let row = try #require(cell.subviews.first as? NSStackView)
        let rowText = row.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(rowText.contains("swim()"))
        let choose = controller.panel.onChoose
        controller.panel.dismiss(); choose?(1)
        try await waitUntil { controller.canGoBack }
        #expect(editor.activeDocumentIntelligenceBuffer == first)
        #expect(editor.activeScintillaView?.anchorUTF8Position == 15)
        controller.moveHistory(back: true)
        try await waitUntil { controller.canGoForward }
        #expect(editor.activeDocumentIntelligenceBuffer == second)
        #expect(editor.activeScintillaView?.caretUTF8Position == 1)
    }
    @Test func protobufRPCTypeJumpsToMessage() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let buffer = try #require(workspace.snapshot().activeBuffer)
        let text = "service IgniteSession { rpc Session(stream ClientMessage) returns (stream ServerMessage) {} }\nmessage ClientMessage {}\nmessage ServerMessage {}"
        editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: text)); editor.display(buffer)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "protobuf"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        let view = try #require(editor.activeScintillaView)
        let use = text[..<text.range(of: "ClientMessage)")!.lowerBound].utf8.count
        let declaration = text[..<text.range(of: "ClientMessage {}")!.lowerBound].utf8.count
        view.setPrimarySelectionUTF8Range(.init(location: use, length: 0))
        let controller = DeclarationNavigationController(workspace: workspace, editor: editor, project: nil, anchor: editor.view, roots: { [] }, actionable: { true }, open: { _ in false })
        defer { controller.cancel() }
        controller.goToDeclaration()
        try await waitUntil { controller.canGoBack }
        #expect(view.anchorUTF8Position == declaration)
        #expect(view.caretUTF8Position == declaration + "ClientMessage".utf8.count)
        #expect(view.contentUTF8 == Data(text.utf8))
        #expect(view.revision == 0)
    }
    @Test func localDeclarationAndHistoryPreserveDocument() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let buffer = try #require(workspace.snapshot().activeBuffer)
        let text = "func swim() {}\nswim()"
        editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: text)); editor.display(buffer)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        let view = try #require(editor.activeScintillaView)
        view.setPrimarySelectionUTF8Range(.init(location: 17, length: 0))
        let controller = DeclarationNavigationController(workspace: workspace, editor: editor, project: nil, anchor: editor.view, roots: { [] }, actionable: { true }, open: { _ in false })
        workspace.onChange = { change in
            if let buffer = change.snapshot.activeBuffer { editor.display(buffer) }
            if change.kind != .persistence { controller.workspaceChanged(change) }
        }
        controller.goToDeclaration()
        try await waitUntil { controller.canGoBack }
        #expect(view.caretUTF8Position == 9 && view.anchorUTF8Position == 5)
        controller.moveHistory(back: true)
        try await waitUntil { controller.canGoForward }
        #expect(editor.navigationPosition?.utf8Offset == 17)
        controller.moveHistory(back: false)
        try await waitUntil { !controller.canGoForward }
        #expect(editor.navigationPosition?.utf8Offset == 9)
        #expect(view.contentUTF8 == Data(text.utf8))
        #expect(view.revision == 0)
        controller.cancel()
    }
    @Test func delayedResultCannotJumpAfterCaretMoves() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = ScintillaEditorAdapter(); defer { editor.invalidate() }
        let buffer = try #require(workspace.snapshot().activeBuffer)
        editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: "func swim() {}\nswim()")); editor.display(buffer)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        let view = try #require(editor.activeScintillaView)
        view.setPrimarySelectionUTF8Range(.init(location: 17, length: 0))
        let analyzer = PausingDeclarationAnalyzer()
        let controller = DeclarationNavigationController(workspace: workspace, editor: editor, project: nil, analyzer: analyzer, anchor: editor.view, roots: { [] }, actionable: { true }, open: { _ in false })
        controller.goToDeclaration()
        view.setPrimarySelectionUTF8Range(.init(location: 0, length: 0))
        await analyzer.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!controller.canGoBack)
        #expect(view.caretUTF8Position == 0 && view.anchorUTF8Position == 0)
        controller.cancel()
    }
    @Test(arguments: [false, true])
    func windowHistoryWaitsForRoutingAndRejectsCaretChanges(moveCaretDuringActivation: Bool) async throws {
        let store = NavigationSessionStore()
        let workspace = ScratchWorkspaceUseCase(store: store)
        let editor = ScintillaEditorAdapter()
        let windowController = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
            markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view, automaticallyStarts: false)
        defer { windowController.close(); editor.invalidate() }
        windowController.start(); await windowController.waitForStartup()
        let first = try #require(workspace.snapshot().activeBuffer)
        editor.install(.init(bufferID: first.bufferID, revision: 0, text: "func swim() {}\nswim()"))
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        editor.activeScintillaView?.setPrimarySelectionUTF8Range(.init(location: 17, length: 0))
        let menu = DuckpadMainMenuFactory.make(target: windowController)
        func allItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) } }
        let declarationItem = try #require(allItems(menu).first { $0.action == #selector(DuckpadWindowController.performGoToDeclaration(_:)) })
        #expect(declarationItem.keyEquivalent == String(UnicodeScalar(NSF12FunctionKey)!))
        #expect(declarationItem.keyEquivalentModifierMask.isEmpty)
        let referencesItem = try #require(allItems(menu).first { $0.action == #selector(DuckpadWindowController.performFindReferences(_:)) })
        #expect(referencesItem.keyEquivalent == String(UnicodeScalar(NSF12FunctionKey)!))
        #expect(referencesItem.keyEquivalentModifierMask == .shift)
        let backItem = try #require(allItems(menu).first { $0.action == #selector(DuckpadWindowController.performNavigationBack(_:)) })
        let forwardItem = try #require(allItems(menu).first { $0.action == #selector(DuckpadWindowController.performNavigationForward(_:)) })
        #expect(backItem.keyEquivalent == "-" && backItem.keyEquivalentModifierMask == .control)
        #expect(forwardItem.keyEquivalent == "-" && forwardItem.keyEquivalentModifierMask == [.control, .shift])
        windowController.performGoToDeclaration(nil)
        try await waitUntil { editor.navigationPosition?.utf8Offset == 9 }
        _ = await workspace.addScratch()
        let second = try #require(workspace.snapshot().activeBuffer)
        editor.install(.init(bufferID: second.bufferID, revision: 0, text: "func swim() {}\nswim()"))
        editor.activeScintillaView?.setPrimarySelectionUTF8Range(.init(location: 2, length: 0))
        await store.pause()
        windowController.performNavigationBack(nil)
        try await waitUntil { workspace.snapshot().activeBuffer == first && workspace.snapshot().persistence == .pending }
        if moveCaretDuringActivation { editor.activeScintillaView?.setPrimarySelectionUTF8Range(.init(location: 0, length: 0)) }
        await store.resume()
        try await waitUntil { workspace.snapshot().persistence == .saved }
        try await Task.sleep(for: .milliseconds(50))
        #expect(editor.activeDocumentIntelligenceBuffer == first)
        #expect(editor.navigationPosition?.utf8Offset == (moveCaretDuringActivation ? 0 : 17))
        if !moveCaretDuringActivation {
            windowController.performNavigationForward(nil)
            try await waitUntil { editor.activeDocumentIntelligenceBuffer == second && editor.navigationPosition?.utf8Offset == 2 }
        }
    }
    @Test func qualifiedCandidatesIncludeUnsavedTabsAndSelectionActivatesExactBuffer() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = ScintillaEditorAdapter()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        defer { editor.invalidate(); window.close() }
        let first = try #require(workspace.snapshot().activeBuffer)
        editor.install(.init(bufferID: first.bufferID, revision: 0, text: "func foo() {}")); editor.display(first)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        _ = await workspace.addScratch()
        let second = try #require(workspace.snapshot().activeBuffer)
        let text = "class Other { func foo() {} }\nremote.foo()"
        editor.install(.init(bufferID: second.bufferID, revision: 0, text: text)); editor.display(second)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        editor.activeScintillaView?.setPrimarySelectionUTF8Range(.init(location: text.utf8.count - 3, length: 0))
        window.makeKeyAndOrderFront(nil); editor.focus()
        let controller = DeclarationNavigationController(workspace: workspace, editor: editor, project: nil, anchor: editor.view, roots: { [] }, actionable: { true }, open: { _ in false })
        defer { controller.cancel() }
        workspace.onChange = { change in
            if let buffer = change.snapshot.activeBuffer { editor.display(buffer) }
            if change.kind != .persistence { controller.workspaceChanged(change) }
        }
        controller.goToDeclaration()
        try await waitUntil { controller.panel.isShown }
        #expect(controller.panel.numberOfRows(in: NSTableView()) == 2)
        let choose = controller.panel.onChoose
        controller.panel.dismiss(); choose?(1)
        try await waitUntil { controller.canGoBack }
        #expect(editor.activeDocumentIntelligenceBuffer == first)
        #expect(editor.activeScintillaView?.caretUTF8Position == 8)
    }
    @Test(arguments: [0, 100])
    func commandClickReportsUTF8OffsetWithoutEditingOrMovingSelection(prefixLines: Int) throws {
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { view.invalidate(); window.close() }
        let prefix = String(repeating: "// 한글🦆\n", count: prefixLines)
        let text = prefix + "func swim() {}\nswim()"
        try view.loadUTF8(Data(text.utf8), revision: 0)
        window.makeKeyAndOrderFront(nil); view.focusEditor(); window.contentView?.layoutSubtreeIfNeeded()
        let client = try #require(window.firstResponder as? any NSTextInputClient)
        let responder = try #require(window.firstResponder as? NSView)
        let original = prefix.utf8.count
        view.restoreCaretUTF8Position(UInt(original), anchorPosition: UInt(original), firstVisibleLine: UInt(prefixLines), horizontalScrollOffset: 0, wordWrapEnabled: false)
        var actual = NSRange()
        let rect = client.firstRect(forCharacterRange: NSRange(location: prefix.utf16.count + 16, length: 1), actualRange: &actual)
        let point = window.convertPoint(fromScreen: NSPoint(x: rect.minX + 1, y: rect.midY))
        var clicked: UInt?
        view.onDeclarationRequested = { clicked = $0 }
        view.setPrimarySelectionUTF8Range(.init(location: original, length: 0))
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        responder.mouseDown(with: event)
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: .command, timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        responder.mouseUp(with: up)
        #expect(clicked == UInt(prefix.utf8.count + 16))
        #expect(view.caretUTF8Position == original && view.anchorUTF8Position == original)
        #expect(view.contentUTF8 == Data(text.utf8))
        #expect(view.revision == 0)
    }
}
