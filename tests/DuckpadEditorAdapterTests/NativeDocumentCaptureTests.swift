import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter
@testable import DuckpadPresentation
import Testing

@Suite(.serialized)
struct NativeDocumentCaptureTests {
    @Test @MainActor func oversizedPreviewReadDoesNotCopyOrCheckpointTheDocument() throws {
        _ = NSApplication.shared
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        editor.install(.init(bufferID: buffer.bufferID, revision: 0,
                             text: String(repeating: "x", count: 512 * 1024 + 1)))
        editor.display(buffer)
        let native = try #require(editor.activeScintillaView)
        let reads = native.snapshotReadCount
        let recovery = try #require(editor.recoveryCapture(for: buffer.bufferID))
        let context = FileWorkspaceContext(tabID: TabID(), title: "large.txt", buffer: buffer, binding: nil)
        #expect(NativeDocumentCapture.read(from: editor, context: context) == nil)
        #expect(native.snapshotReadCount == reads)
        let after = try #require(editor.recoveryCapture(for: buffer.bufferID))
        #expect(after.checkpoint.utf8.withUnsafeBytes { afterBytes in
            recovery.checkpoint.utf8.withUnsafeBytes { $0.baseAddress == afterBytes.baseAddress }
        })
    }
    @Test @MainActor func boundedPreviewReadsCurrentUTF8AndRejectsStaleContext() throws {
        _ = NSApplication.shared
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: "@startuml\nactor 고객\n@enduml"))
        editor.display(buffer)
        let context = FileWorkspaceContext(tabID: TabID(), title: "test.puml", buffer: buffer, binding: nil)
        #expect(NativeDocumentCapture.read(from: editor, context: context) == "@startuml\nactor 고객\n@enduml")
        let stale = FileWorkspaceContext(tabID: context.tabID, title: context.title,
            buffer: EditorBufferDescriptor(bufferID: buffer.bufferID, revision: 1), binding: nil)
        #expect(NativeDocumentCapture.read(from: editor, context: stale) == nil)
    }
}
