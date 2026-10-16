import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadScintillaBridge
import Testing

private actor HoverLookupGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

/// SwiftPM has no NSApplication event loop to deliver window activation.
@MainActor private final class HoverTestWindow: NSWindow {
    var simulatedKey = true
    override var isKeyWindow: Bool { simulatedKey }
}

@Suite(.serialized) @MainActor
struct DeclarationHoverTests {
    init() { _ = NSApplication.shared; ScintillaEditorAdapter.prepareResources() }

    @Test(arguments: [false, true])
    func delayedLookupCannotRestoreHoverAfterCancellation(reload: Bool) async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = ScintillaEditorAdapter()
        let window = HoverTestWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        defer { editor.invalidate(); window.close() }
        let buffer = try #require(workspace.snapshot().activeBuffer)
        editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: "func swim() {}\nswim()")); editor.display(buffer)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: "swift"), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        let view = try #require(editor.activeScintillaView)
        window.makeKeyAndOrderFront(nil); editor.focus(); window.contentView?.layoutSubtreeIfNeeded()
        let responder = try #require(window.firstResponder as? NSView)
        let client = try #require(responder as? any NSTextInputClient)
        let gate = HoverLookupGate()
        editor.onDeclarationHoverRequested = { _, _, _ in await gate.wait(); return true }
        var actual = NSRange()
        let rect = client.firstRect(forCharacterRange: NSRange(location: 16, length: 1), actualRange: &actual)
        let point = window.convertPoint(fromScreen: NSPoint(x: rect.minX + 1, y: rect.midY))
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        responder.mouseMoved(with: event)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.entered)
        if reload { try view.loadUTF8(Data("func duck() {}\nswim()".utf8), revision: 0) }
        else {
            let release = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
            responder.flagsChanged(with: release)
        }
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.declarationHoverRange.length == 0)
        #expect((responder.value(forKey: "declarationLinkCursor") as? Bool) == false)
    }

    @Test(arguments: ["swift", "protobuf"])
    func hoverDecoratesWithoutEditingAndReusesAnalysis(language: String) async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = ScintillaEditorAdapter()
        let window = HoverTestWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        defer { editor.invalidate(); window.close() }
        let buffer = try #require(workspace.snapshot().activeBuffer)
        let text = language == "protobuf"
            ? "enum swim {}  \nswim x\n// swim\noption a = \"swim\";"
            : "func swim() {}\nswim()\n// swim\nlet text = \"swim\""
        editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: text)); editor.display(buffer)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: language), lexerName: "cpp", indentation: .init(), folding: false, braceMatching: false))
        let view = try #require(editor.activeScintillaView)
        window.makeKeyAndOrderFront(nil); editor.focus(); window.contentView?.layoutSubtreeIfNeeded()
        let responder = try #require(window.firstResponder as? NSView)
        let client = try #require(responder as? any NSTextInputClient)
        func move(_ offset: Int, flags: NSEvent.ModifierFlags = .command) throws {
            var actual = NSRange()
            let rect = client.firstRect(forCharacterRange: NSRange(location: offset, length: 1), actualRange: &actual)
            let point = window.convertPoint(fromScreen: NSPoint(x: rect.minX + 1, y: rect.midY))
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
            responder.mouseMoved(with: event)
        }
        func modifiers(_ flags: NSEvent.ModifierFlags) throws {
            let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
            responder.flagsChanged(with: event)
        }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        let reads = view.snapshotReadCount
        try move(16, flags: [])
        try await Task.sleep(for: .milliseconds(70))
        #expect(view.snapshotReadCount == reads)
        #expect(view.declarationHoverRange.length == 0)
        try modifiers(.command)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while view.declarationHoverRange.length == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(view.snapshotReadCount > reads)
        #expect(view.declarationHoverRange == NSRange(location: 15, length: 4))
        #expect((responder.value(forKey: "declarationLinkCursor") as? Bool) == true)
        #expect(view.caretUTF8Position == 0 && view.anchorUTF8Position == 0)
        #expect(view.revision == 0)
        let cachedReads = view.snapshotReadCount
        try modifiers([])
        #expect(view.declarationHoverRange.length == 0)
        #expect((responder.value(forKey: "declarationLinkCursor") as? Bool) == false)
        try move(6)
        #expect(view.declarationHoverRange == NSRange(location: 5, length: 4))
        #expect(view.snapshotReadCount == cachedReads)
        try move(24) // comment
        #expect(view.declarationHoverRange.length == 0)
        try move(41) // string literal
        #expect(view.declarationHoverRange.length == 0)
        try move(19) // punctuation immediately following the identifier
        #expect(view.declarationHoverRange.length == 0)
        try move(16)
        #expect(view.declarationHoverRange.length == 4)
        window.simulatedKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(view.declarationHoverRange.length == 0)
        window.simulatedKey = true
        try move(16)
        #expect(view.declarationHoverRange.length == 4)
        try view.loadUTF8(Data(text.utf8), revision: 0) // Reloads may keep the same revision.
        let reloadReads = view.snapshotReadCount
        try move(16)
        try modifiers([]) // Cancel the debounced capture before it starts.
        try await Task.sleep(for: .milliseconds(70))
        #expect(view.declarationHoverRange.length == 0)
        #expect(view.snapshotReadCount == reloadReads)
        try modifiers(.command)
        let reloadDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while view.declarationHoverRange.length == 0, ContinuousClock.now < reloadDeadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(view.declarationHoverRange.length == 4)
        #expect(view.snapshotReadCount > reloadReads)
        client.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.declarationHoverRange.length == 0)
        client.unmarkText()
    }

    @Test(arguments: ["swift", "json"])
    func excludedDocumentsDoNotCaptureSnapshots(language: String) async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let buffer = try #require(workspace.snapshot().activeBuffer)
        let text = language == "swift" ? "swim\n" + String(repeating: " ", count: DeclarationIndex.maximumBytes) : "swim"
        editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: text)); editor.display(buffer)
        _ = editor.applyLanguage(.init(languageID: .init(rawValue: language), lexerName: "null", indentation: .init(), folding: false, braceMatching: false))
        let view = try #require(editor.activeScintillaView)
        let reads = view.snapshotReadCount
        view.onDeclarationHovered?(1)
        try await Task.sleep(for: .milliseconds(80))
        #expect(view.snapshotReadCount == reads)
    }

    @Test func editsInAnotherPaneClearSharedHover() throws {
        let primary = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 350, height: 300))
        let peer = DPScintillaEditorView(frame: NSRect(x: 350, y: 0, width: 350, height: 300))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        container.addSubview(primary); container.addSubview(peer)
        let window = HoverTestWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = container
        defer { peer.invalidate(); primary.invalidate(); window.close() }
        let text = Data("func swim() {}\nswim()".utf8)
        try primary.loadUTF8(text, revision: 0)
        peer.shareDocument(with: primary)
        window.makeKeyAndOrderFront(nil); peer.focusEditor(); container.layoutSubtreeIfNeeded()
        let responder = try #require(window.firstResponder as? NSView)
        let client = try #require(responder as? any NSTextInputClient)
        var actual = NSRange()
        let rect = client.firstRect(forCharacterRange: NSRange(location: 16, length: 1), actualRange: &actual)
        let point = window.convertPoint(fromScreen: NSPoint(x: rect.minX + 1, y: rect.midY))
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        peer.onDeclarationHovered = { [weak peer] position in
            guard let peer, position != NSNotFound else { return }
            _ = peer.showDeclarationHover(NSRange(location: 15, length: 4), expectedRevision: peer.revision, expectedPosition: position)
        }
        primary.focusEditor()
        let focused = window.firstResponder
        responder.mouseMoved(with: event)
        #expect(window.firstResponder === focused)
        #expect(peer.declarationHoverRange.length == 4)
        let generation = peer.declarationContentGeneration
        let primaryClient = try #require(focused as? any NSTextInputClient)
        primaryClient.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(peer.declarationHoverRange.length == 0)
        #expect((responder.value(forKey: "declarationLinkCursor") as? Bool) == false)
        #expect(peer.declarationContentGeneration != generation)
        primary.undo()
        responder.mouseMoved(with: event)
        #expect(peer.declarationHoverRange.length == 4)
        try primary.loadUTF8(text, revision: 0)
        #expect(peer.declarationHoverRange.length == 0)
    }
}
