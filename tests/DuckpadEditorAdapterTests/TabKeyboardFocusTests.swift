import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadEditorAdapter
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct TabKeyboardFocusTests {
    @Test func keyboardTabNavigationPreservesFocusAndAcceptsTypingInDestination() async throws {
        _ = NSApplication.shared
        ScintillaEditorAdapter.prepareResources()
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
            markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view, automaticallyStarts: false)
        defer { controller.close(); editor.invalidate() }
        controller.start(); await controller.waitForStartup()
        _ = await workspace.addScratch()
        let window = try #require(controller.window)
        editor.focus()
        for command in [TabNavigationCommand.previous, .next, .lastUsed] {
            let old = try #require(workspace.snapshot().activeBuffer)
            switch command {
            case .previous: controller.performPreviousTab()
            case .next: controller.performNextTab()
            case .lastUsed: controller.performLastUsedTab()
            }
            for _ in 0..<100 {
                if workspace.snapshot().activeBuffer?.bufferID != old.bufferID { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let destination = try #require(workspace.snapshot().activeBuffer)
            #expect(destination.bufferID != old.bufferID)
            let active = try #require(editor.activeScintillaView)
            #expect(active.hasEditorFocus)
            // Activation publishes the destination before its session commit finishes.
            // The workspace rejects edits during that transaction, independently of focus.
            // Check focus immediately, then type once activation has completed.
            for _ in 0..<100 {
                if workspace.snapshot().persistence == .saved { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(workspace.snapshot().persistence == .saved)
            try #require(workspace.snapshot().activeBuffer?.bufferID == destination.bufferID)
            let client = try #require(window.firstResponder as? any NSTextInputClient)
            let before = editor.snapshot(for: destination.bufferID)?.text ?? ""
            client.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(editor.snapshot(for: destination.bufferID)?.text == before + "x")
        }
    }
    @Test(arguments: [false, true])
    func replacingVisibleBufferPreservesOnlyExistingEditorFocus(grouped: Bool) throws {
        _ = NSApplication.shared
        let editor = ScintillaEditorAdapter()
        let first = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let second = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        editor.install(.init(bufferID: first.bufferID, revision: 0, text: "first"))
        editor.install(.init(bufferID: second.bufferID, revision: 0, text: "second"))
        editor.display(first)
        if grouped { editor.setEditorGroupOrientation(.sideBySide) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.view
        defer { editor.invalidate(); window.contentView = nil; window.close() }
        editor.focus()
        #expect(editor.activeScintillaView?.hasEditorFocus == true)
        editor.display(second)
        #expect(editor.activeScintillaView?.hasEditorFocus == true)
        #expect(window.firstResponder is any NSTextInputClient)

        // A background tab activation must not steal focus from another control.
        let control = NSButton(title: "Test control", target: nil, action: nil)
        editor.view.addSubview(control)
        #expect(window.makeFirstResponder(control))
        editor.display(first)
        #expect(window.firstResponder === control)
        #expect(editor.activeScintillaView?.hasEditorFocus == false)
    }

}
