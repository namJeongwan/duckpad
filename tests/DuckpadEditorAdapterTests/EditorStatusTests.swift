import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter
import Testing

@Suite(.serialized)
struct EditorStatusTests {
    @Test @MainActor func statusReportsNativePositionUnicodeSelectionAndOverwriteMode() throws {
        let adapter = ScintillaEditorAdapter()
        defer { adapter.invalidate() }
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: "a🦆\nhello"))
        adapter.display(buffer)
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 1, length: 5))
        let status = try #require(adapter.editorStatus)
        #expect(status.length == 11)
        #expect(status.lines == 2)
        #expect(status.line == 2)
        #expect(status.column == 1)
        #expect(status.selectedCharacters == 2)
        #expect(status.selectedLines == 1)
        #expect(!status.isOvertype)
        var updates = 0
        adapter.onEditorStatusChange = { updates += 1 }
        adapter.toggleOvertype()
        #expect(adapter.editorStatus?.isOvertype == true)
        #expect(updates >= 1)
        view.setPrimarySelectionUTF8Range(NSRange(location: 11, length: 0))
        #expect(adapter.editorStatus?.column == 6)
        #expect(adapter.editorStatus?.selectedCharacters == 0)
        #expect(adapter.editorStatus?.selectedLines == 0)
        adapter.setInputEnabled(false)
        adapter.toggleOvertype()
        #expect(adapter.editorStatus?.isOvertype == true)
    }
}
