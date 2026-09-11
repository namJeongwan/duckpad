import AppKit
import DuckpadScintillaBridge
import Testing

@Suite(.serialized)
@MainActor
struct FullBinaryDocumentTests {
    @Test func incrementalRawBytesKeepSelectionsAndReadOnlySharedViews() async throws {
        _ = NSApplication.shared
        var bytes = Data(repeating: 0x80, count: 2 * 1_024 * 1_024)
        for index in stride(from: 31, to: bytes.count, by: 32) { bytes[index] = 0x0A }
        bytes.append(contentsOf: [0, 0xFF, 0x54, 0x41, 0x49, 0x4C])
        let document = try await DPScintillaBinaryDocument.begin(data: bytes)
        #expect(document.byteLength == 65_536)
        #expect(document.totalByteLength == UInt(bytes.count))
        let primary = DPScintillaEditorView(frame: .zero)
        let peer = DPScintillaEditorView(frame: .zero)
        defer { primary.invalidate(); peer.invalidate() }
        primary.load(document, revision: 7)
        peer.shareDocument(with: primary)
        #expect(primary.contentUTF8 == bytes.prefix(65_536))
        primary.restoreCaretUTF8Position(65_536, anchorPosition: 65_536,
            firstVisibleLine: 2, horizontalScrollOffset: 0, wordWrapEnabled: false)
        peer.setPrimarySelectionUTF8Range(NSRange(location: 5, length: 9))
        #expect(peer.addSelectionUTF8Range(NSRange(location: 20, length: 3)))
        let peerCaret = peer.caretUTF8Position
        let peerAnchor = peer.anchorUTF8Position
        let firstVisibleLine = primary.firstVisibleLine
        var edits = 0
        var preflights = 0
        var statusCalls = 0
        for view in [primary, peer] {
            view.onEdit = { _ in edits += 1 }
            view.onWillModifyDocument = { preflights += 1 }
            view.onStatusChange = {
                statusCalls += 1
                #expect(!view.isInputEnabled)
            }
        }
        var complete = false
        while !complete {
            let previousLength = document.byteLength
            complete = try primary.appendBinaryDocumentChunk(document, maximumBytes: 1_024 * 1_024)
            #expect(document.byteLength > previousLength)
            #expect(primary.documentByteLength == document.byteLength)
            #expect(peer.documentByteLength == document.byteLength)
            #expect(primary.caretUTF8Position == 65_536)
            #expect(primary.anchorUTF8Position == 65_536)
            #expect(primary.firstVisibleLine == firstVisibleLine)
            #expect(peer.caretUTF8Position == peerCaret)
            #expect(peer.anchorUTF8Position == peerAnchor)
            #expect(peer.selectionCount == 2)
            for view in [primary, peer] {
                view.isInputEnabled = true
                view.insertCommittedText("blocked")
                #expect(!view.isInputEnabled)
                #expect(view.revision == 7)
                #expect(!view.canUndo)
            }
        }
        #expect(edits == 0)
        #expect(preflights == 0)
        #expect(statusCalls > 0)
        #expect(document.byteLength == document.totalByteLength)
        #expect(primary.contentUTF8 == bytes)
        #expect(peer.contentUTF8 == bytes)
        #expect(try primary.appendBinaryDocumentChunk(document, maximumBytes: 1))
        #expect(throws: NSError.self) {
            try primary.appendBinaryDocumentChunk(document, maximumBytes: 0)
        }
        let cancelled = try await DPScintillaBinaryDocument.begin(data: bytes)
        primary.load(cancelled, revision: 11)
        cancelled.cancelLoading()
        #expect(throws: NSError.self) {
            try primary.appendBinaryDocumentChunk(cancelled, maximumBytes: 1_024)
        }
        #expect(primary.documentByteLength == 65_536)
        #expect(primary.contentUTF8 == bytes.prefix(65_536))
        #expect(!primary.isInputEnabled)
    }

    @Test func fullRawBytesRemainReadOnlyAcrossSharedViewsAndTextReload() async throws {
        _ = NSApplication.shared
        var bytes = Data(repeating: 0x80, count: 2 * 1_024 * 1_024)
        bytes.replaceSubrange(0..<6, with: [0, 0xFF, 0xC0, 0xAF, 0x0D, 0x0A])
        let tail = Data([0x0A, 0xFF, 0, 0x54, 0x41, 0x49, 0x4C])
        bytes.append(tail)
        var prepared: DPScintillaBinaryDocument? = try await DPScintillaBinaryDocument.prepare(data: bytes)
        #expect(prepared?.byteLength == UInt(bytes.count))
        let primary = DPScintillaEditorView(frame: .zero)
        let peer = DPScintillaEditorView(frame: .zero)
        defer { primary.invalidate(); peer.invalidate() }
        primary.load(try #require(prepared), revision: 7)
        peer.shareDocument(with: primary)
        prepared = nil

        for view in [primary, peer] {
            #expect(view.documentByteLength == UInt(bytes.count))
            #expect(view.contentUTF8 == bytes)
            #expect(try view.utf8Bytes(in: NSRange(location: bytes.count - tail.count,
                length: tail.count)) == tail)
            view.isInputEnabled = true
            view.synchronizeRevision(8)
            #expect(!view.isInputEnabled)
            view.restoreCaretUTF8Position(UInt(bytes.count - 8), anchorPosition: UInt(bytes.count - 8),
                firstVisibleLine: 0, horizontalScrollOffset: 0, wordWrapEnabled: true)
            #expect(view.caretColumn == UInt(bytes.count - 8 - 6))
            #expect(!view.isWordWrapEnabled)
            view.insertCommittedText("must not change")
            view.selectAll()
            #expect(view.selectedCharacterCount == UInt(bytes.count))
            view.deleteSelectionOrNextCharacter()
            view.undo()
            #expect(view.contentUTF8 == bytes)
            #expect(!view.canUndo)
            #expect(!view.canRedo)
        }

        try primary.loadUTF8(Data("let value = 1\n".utf8), revision: 9)
        peer.shareDocument(with: primary)
        #expect(primary.isInputEnabled)
        #expect(peer.isInputEnabled)
        #expect(primary.applyLexerNamed("cpp", keywords: ["let"], tabWidth: 4,
            useTabs: false, folding: false, braceMatching: false, maximumStyleBytes: 1_024))
        #expect(primary.style(atUTF8Position: 0) != 0)
        primary.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        primary.insertCommittedText("x")
        #expect(primary.canUndo)
        #expect(peer.contentUTF8 == Data("xlet value = 1\n".utf8))
        primary.undo()
        #expect(peer.contentUTF8 == Data("let value = 1\n".utf8))
    }
}
