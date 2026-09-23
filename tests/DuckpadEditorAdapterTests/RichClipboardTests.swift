import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadScintillaBridge
@testable import DuckpadEditorAdapter
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct RichClipboardTests {
    private func fixture(_ text: String, renderer: (any MarkdownClipboardRendering)? = nil) throws -> (ScintillaEditorAdapter, DPScintillaEditorView) {
        _ = NSApplication.shared
        let adapter = ScintillaEditorAdapter(markdownClipboardRenderer: renderer)
        adapter.applyPreferences(AppSettings(defaultWordWrapEnabled: false))
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        adapter.display(EditorBufferDescriptor(bufferID: BufferID(), revision: 0))
        let view = try #require(adapter.activeScintillaView)
        if text.utf8.count > 4096 {
            try view.loadUTF8(Data(text.utf8), revision: 1)
        } else {
            view.insertCommittedText(text)
        }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: text.utf8.count))
        return (adapter, view)
    }

    /// Restore the pre-test pasteboard, without logging its contents.
    private func preservingClipboard(_ operation: () throws -> Void) rethrows {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            board.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        try operation()
    }

    @Test func nativeCopyAddsRichFormatsAndKeepsOriginalBytesAndUndo() throws {
        let text = "# RiLACC\r\n\t- 한글 🙂 <script>&\"\r\n  end\r\n"
        let (adapter, view) = try fixture(text)
        defer { adapter.invalidate() }
        let reads = view.snapshotReadCount
        let revision = view.revision
        try preservingClipboard {
            // Exercise the native callback, not only the application command.
            view.copySelection()
            let board = NSPasteboard.general
            #expect(board.string(forType: .string) == text)
            let html = try #require(board.string(forType: .html))
            #expect(html.contains("&lt;script&gt;&amp;&quot;"))
            #expect(html.contains("\r\n\t- 한글 🙂"))
            #expect(html.contains("white-space:pre-wrap"))
            #expect(!html.contains("<h1"))
            let rtf = try #require(board.data(forType: .rtf))
            let decoded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            #expect(decoded.string.replacingOccurrences(of: "\r\n", with: "\n") == text.replacingOccurrences(of: "\r\n", with: "\n"))
            #expect(board.data(forType: .png) == nil)
            #expect(view.revision == revision)
            #expect(view.snapshotReadCount == reads)
            #expect(view.canUndo)
            adapter.perform(.undo)
            #expect(view.contentUTF8.isEmpty)
        }
    }

    @Test func plainCopyAndDisabledPreferenceDoNotLeaveStaleHTML() throws {
        let (adapter, _) = try fixture("plain 한글")
        defer { adapter.invalidate() }
        preservingClipboard {
            adapter.perform(.copy)
            #expect(NSPasteboard.general.data(forType: .html) != nil)
            adapter.copyAsPlainText()
            #expect(NSPasteboard.general.string(forType: .string) == "plain 한글")
            #expect(NSPasteboard.general.data(forType: .html) == nil)
            var settings = AppSettings.defaults
            settings.copyWithFormatting = false
            adapter.applyPreferences(settings)
            adapter.perform(.copy)
            #expect(NSPasteboard.general.data(forType: .rtf) == nil)
            #expect(NSPasteboard.general.data(forType: .html) == nil)
        }
    }

    @Test func boundsAndMultipleSelectionsKeepNativeCopy() throws {
        let text = String(repeating: "x", count: RichClipboardWriter.maximumTextBytes + 1)
        let (adapter, view) = try fixture(text)
        defer { adapter.invalidate() }
        preservingClipboard {
            adapter.perform(.copy)
            #expect(NSPasteboard.general.string(forType: .string)?.utf8.count == text.utf8.count)
            #expect(NSPasteboard.general.data(forType: .html) == nil)
            view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 2))
            #expect(view.addSelectionUTF8Range(NSRange(location: 5, length: 2)))
            #expect(view.copyPresentation(withMaximumBytes: 1024) == nil)
            adapter.perform(.copy)
            #expect(NSPasteboard.general.string(forType: .string) != nil)
            #expect(NSPasteboard.general.data(forType: .html) == nil)
        }
    }

    @Test func tinySelectionInLargeDocumentDoesNotReadOrStyleWholeDocument() throws {
        let (adapter, view) = try fixture(String(repeating: "abc\n", count: 300_000))
        defer { adapter.invalidate() }
        view.setPrimarySelectionUTF8Range(NSRange(location: 1_199_996, length: 3))
        let reads = view.snapshotReadCount
        let styles = view.synchronouslyStyledByteCount
        let presentation = try #require(view.copyPresentation(withMaximumBytes: 1024))
        #expect(presentation.string == "abc")
        #expect(view.snapshotReadCount == reads)
        #expect(view.synchronouslyStyledByteCount == styles)
    }

    @Test func imageCopyProducesPNGAndOversizedImagePreservesClipboard() throws {
        let (adapter, view) = try fixture("RiLACC\n  - 한글 🙂\n    end")
        defer { adapter.invalidate() }
        let revision = view.revision
        try preservingClipboard {
            #expect(adapter.copyAsImage())
            let board = NSPasteboard.general
            let png = try #require(board.data(forType: .png))
            if let path = ProcessInfo.processInfo.environment["DUCKPAD_COPY_PREVIEW_PATH"] {
                try png.write(to: URL(fileURLWithPath: path))
            }
            let bitmap = try #require(NSBitmapImageRep(data: png))
            #expect(bitmap.pixelsWide > 48 && bitmap.pixelsHigh > 48)
            #expect(board.string(forType: .string) == nil)
            let changeCount = board.changeCount
            let oversized = NSAttributedString(string: String(repeating: "W", count: 60_000))
            #expect(!RichClipboardWriter.copyImage(oversized, to: board))
            #expect(board.changeCount == changeCount)
            #expect(board.data(forType: .png) == png)
            #expect(view.revision == revision)
        }
    }

    @Test func styledCopyUsesLightPaletteWithoutChangingEditorTheme() throws {
        let (adapter, view) = try fixture("int answer = 42; // hello")
        defer { adapter.invalidate() }
        #expect(adapter.applyLanguage(.init(languageID: .init(rawValue: "cpp"), lexerName: "cpp",
            keywords: ["int return"], indentation: .init(), folding: true, braceMatching: true)))
        view.apply(.dark)
        let presentation = try #require(view.copyPresentation(withMaximumBytes: 1024))
        let html = try #require(RichClipboardWriter.html(presentation, tabWidth: 4))
        let output = String(decoding: html, as: UTF8.self)
        #expect(output.contains("color:#003ba2"))
        #expect(output.contains("color:#8e2f7c"))
        #expect(output.contains("background-color:#ffffff"))
        #expect(view.foregroundColor(forStyle: 0) == 0xE8E8E8)
    }

    @Test func staleTextIsNotEnriched() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("new copy", forType: .string)
        RichClipboardWriter.addRepresentations(NSAttributedString(string: "old copy"), tabWidth: 4, to: board)
        #expect(board.string(forType: .string) == "new copy")
        #expect(board.data(forType: .html) == nil)
    }

    @Test func oldSettingsDefaultToRichCopyAndPreferenceRoundTrips() throws {
        let encoded = try JSONEncoder().encode(AppSettings.defaults)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "copyWithFormatting")
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.copyWithFormatting)
        var settings = old
        settings.copyWithFormatting = false
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    private final class MarkdownRenderer: MarkdownClipboardRendering {
        var source: String?
        var output: Data? = Data("<h2>제목</h2>".utf8)
        func html(for source: String) -> Data? { self.source = source; return output }
    }

    @Test(arguments: [false, true]) func nativeCutKeepsPlainClipboardAndUndo(markdown: Bool) throws {
        let source = "## 제목\r\n- 한글 🙂\r\n"
        let renderer = MarkdownRenderer()
        let (adapter, view) = try fixture(source, renderer: renderer)
        defer { adapter.invalidate() }
        if markdown {
            #expect(adapter.applyLanguage(.init(languageID: .init(rawValue: "markdown"), lexerName: "markdown",
                indentation: .init(), folding: false, braceMatching: false)))
        }
        preservingClipboard {
            view.copySelection()
            renderer.source = nil
            view.cutSelection()
            #expect(NSPasteboard.general.string(forType: .string) == source)
            #expect(NSPasteboard.general.data(forType: .html) == nil)
            #expect(NSPasteboard.general.data(forType: .rtf) == nil)
            #expect(renderer.source == nil)
            #expect(view.contentUTF8.isEmpty)
            adapter.perform(.undo)
            #expect(view.contentUTF8 == Data(source.utf8))
        }
    }

    @Test func exportedFontIncludesEditorZoomAndLineSpacing() throws {
        let (adapter, view) = try fixture("import pandas as pd\n\ndf = pd.DataFrame()")
        defer { adapter.invalidate() }
        view.configureEditorFont("Courier", size: 13.5)
        view.configureTextLayout(withLeftPadding: 2, rightPadding: 2, lineSpacing: 4)
        view.zoomLevel = 3
        let text = try #require(view.copyPresentation(withMaximumBytes: 1024))
        let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.familyName == "Courier")
        #expect(font.pointSize == 16.5)
        let paragraph = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.minimumLineHeight > font.pointSize)
        #expect(paragraph.minimumLineHeight == paragraph.maximumLineHeight)
        view.zoomLevel = -10
        view.configureEditorFont("Courier", size: 6)
        let small = try #require(view.copyPresentation(withMaximumBytes: 1024))
        #expect((small.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 1)
    }

    @Test func browserCodeFontMatchesNativeSizeInsteadOfGrowingByOneThird() async throws {
        let (adapter, view) = try fixture("import pandas as pd\n\ndf = pd.DataFrame()")
        defer { adapter.invalidate() }
        view.configureEditorFont("Menlo", size: 13)
        view.zoomLevel = 0
        let text = try #require(view.copyPresentation(withMaximumBytes: 1024))
        let html = try #require(RichClipboardWriter.html(text, tabWidth: 4))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        web.loadHTMLString(String(decoding: html, as: UTF8.self), baseURL: nil)
        var ready = false
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!document.querySelector('pre span')")) as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(ready)
        let computed = try #require(try await web.evaluateJavaScript("(()=>{const s=getComputedStyle(document.querySelector('pre span'));const p=getComputedStyle(document.querySelector('pre'));return {size:s.fontSize,family:s.fontFamily,line:p.lineHeight,base:p.fontSize};})()") as? [String: String])
        #expect(computed["size"] == "13px")
        #expect(computed["base"] == "13px")
        #expect(computed["family"]?.contains("Menlo") == true)
        let browserWidth = try #require(try await web.evaluateJavaScript("(()=>{const c=document.createElement('canvas').getContext('2d');c.font=getComputedStyle(document.querySelector('pre span')).font;return c.measureText('import pandas as pd').width;})()") as? Double)
        let nativeFont = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let nativeWidth = NSAttributedString(string: "import pandas as pd", attributes: [.font: nativeFont]).size().width
        #expect(abs(browserWidth - nativeWidth) < 1)
        let paragraph = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(computed["line"] == "\(Int(paragraph.minimumLineHeight))px")
    }

    @Test func markdownNativeCopyRendersHTMLButKeepsSourceAndPlainOverride() throws {
        let source = "## 제목\r\n- 한글 🙂\r\n"
        let renderer = MarkdownRenderer()
        let (adapter, view) = try fixture(source, renderer: renderer)
        defer { adapter.invalidate() }
        #expect(adapter.applyLanguage(.init(languageID: .init(rawValue: "markdown"), lexerName: "markdown",
            indentation: .init(), folding: false, braceMatching: false)))
        let revision = view.revision
        preservingClipboard {
            view.copySelection()
            #expect(renderer.source == source)
            #expect(NSPasteboard.general.string(forType: .string) == source)
            #expect(NSPasteboard.general.string(forType: .html) == "<h2>제목</h2>")
            #expect(NSPasteboard.general.data(forType: .rtf) == nil)
            #expect(view.revision == revision)
            #expect(view.contentUTF8 == Data(source.utf8))
            adapter.copyAsPlainText()
            #expect(NSPasteboard.general.string(forType: .string) == source)
            #expect(NSPasteboard.general.data(forType: .html) == nil)
            renderer.output = nil
            view.copySelection()
            #expect(NSPasteboard.general.string(forType: .string) == source)
            #expect(NSPasteboard.general.data(forType: .html) == nil)
            #expect(NSPasteboard.general.data(forType: .rtf) == nil)
        }
    }
}
