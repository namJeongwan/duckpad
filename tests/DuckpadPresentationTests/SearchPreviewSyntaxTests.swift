import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct SearchPreviewSyntaxTests {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func highlighter() throws -> ScintillaSearchPreviewHighlighter {
        _ = NSApplication.shared
        return ScintillaSearchPreviewHighlighter(registry: try LanguageManifestLoader().loadBundled())
    }
    private func utf8Range(_ token: String, in text: String) throws -> SearchUTF8Range {
        let found = try #require(text.range(of: token))
        return .init(location: text[..<found.lowerBound].utf8.count, length: token.utf8.count)
    }
    private func rgb(_ value: Any?) throws -> Int {
        let native = try #require(value as? NSColor)
        let color = try #require(native.usingColorSpace(.sRGB))
        return (Int((color.redComponent * 255).rounded()) << 16)
            | (Int((color.greenComponent * 255).rounded()) << 8) | Int((color.blueComponent * 255).rounded())
    }
    private func foreground(_ token: String, in view: SearchCodePreviewView) throws -> Int {
        let text = view.textView.string
        let found = try #require(text.range(of: token))
        return try rgb(view.textView.textStorage?.attribute(.foregroundColor,
            at: text[..<found.lowerBound].utf16.count, effectiveRange: nil))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "Syntax preview did not arrive")
    }

    @Test(arguments: [
        ("preview.rs", "fn main() { let message = \"IGNITE\"; // 한글 🦆\n let count = 42; }"),
        ("preview.py", "def main():\n    message = \"IGNITE\" # 한글 🦆\n    return 42"),
        ("preview.rb", "def main\n  message = \"IGNITE\" # 한글 🦆\n  42\nend"),
        ("preview.json", "{\"name\": \"IGNITE 한글 🦆\", \"count\": 42, \"enabled\": true}"),
        ("preview.yml", "name: \"IGNITE 한글 🦆\"\ncount: 42\n# comment\n")
    ])
    func usesNativeLanguageColorsWithoutChangingExcerpt(filename: String, source: String) throws {
        let input = SearchMatchPreview(text: source, firstLine: 1, matchLine: 1, highlight: try utf8Range("IGNITE", in: source))
        let output = try highlighter().highlight(input, filename: filename, languageOverride: .automatic)
        #expect(output.text == input.text)
        #expect(output.highlight == input.highlight)
        #expect(!output.syntax.isEmpty)
        #expect(Set(output.syntax.map(\.lightForeground)).count >= 2)
        let bytes = Data(source.utf8)
        for span in output.syntax {
            #expect(span.range.location >= 0 && span.range.upperBound <= bytes.count)
            #expect(String(data: bytes.subdata(in: span.range.location..<span.range.upperBound), encoding: .utf8) != nil)
        }
    }

    @Test func commentsOpenedBeforeTheExcerptKeepTheirLexerState() throws {
        let source = "/* comment starts\n" + String(repeating: "still comment\n", count: 20)
            + "fn inner() { let message = \"IGNITE\"; }\n*/\nfn real() {}\n"
        let input = try #require(SearchMatchPreview.extract(utf8: Data(source.utf8),
            range: try utf8Range("IGNITE", in: source), line: 22))
        #expect(!input.text.contains("/*"))
        #expect(input.syntaxContextPrefix.contains("/*"))
        let output = try highlighter().highlight(input, filename: "preview.rs", languageOverride: .automatic)
        let word = try utf8Range("fn inner", in: output.text)
        let span = try #require(output.syntax.first { $0.range.location <= word.location && $0.range.upperBound >= word.upperBound })
        #expect(span.lightForeground == EditorThemePalette.light.colors.comment)
        #expect(span.darkForeground == EditorThemePalette.dark.colors.comment)
    }

    @Test func plainTextFallbackAndLargeInputRemainBounded() throws {
        let lexer = try highlighter(), text = "fn main() { let value = \"IGNITE\"; }"
        let input = SearchMatchPreview(text: text, firstLine: 1, matchLine: 1, highlight: try utf8Range("IGNITE", in: text))
        let styled = lexer.highlight(input, filename: "preview.rs", languageOverride: .automatic)
        #expect(!styled.syntax.isEmpty)
        #expect(lexer.highlight(styled, filename: "preview.rs", languageOverride: .manual(.plainText)).syntax.isEmpty)
        let long = SearchMatchPreview(text: String(repeating: "x", count: 32 * 1024 + 1), firstLine: 1, matchLine: 1,
            highlight: .init(location: 0, length: 1))
        #expect(lexer.highlight(long, filename: "preview.rs", languageOverride: .automatic).syntax.isEmpty)
        let source = String(repeating: "// 한글 🦆\n", count: 7000) + text
        let excerpt = try #require(SearchMatchPreview.extract(utf8: Data(source.utf8), range: try utf8Range("IGNITE", in: source), line: 7001))
        #expect(excerpt.text.utf8.count <= 32 * 1024)
        #expect(excerpt.syntaxContextPrefix.utf8.count <= 64 * 1024)
        #expect(excerpt.languageDetectionPrefix?.count == 64 * 1024)
    }

    @Test(arguments: ["python3", "ruby"])
    func extensionlessScriptsKeepTheirLanguageFarFromTheShebang(interpreter: String) throws {
        let source = "#!/usr/bin/env \(interpreter)\n" + String(repeating: "# padding 한글 🦆\n", count: 7000)
            + "def main\n    message = \"IGNITE\"\n"
        let input = try #require(SearchMatchPreview.extract(utf8: Data(source.utf8),
            range: try utf8Range("IGNITE", in: source), line: 7003))
        #expect(!input.syntaxContextPrefix.contains("#!"))
        let output = try highlighter().highlight(input, filename: "script", languageOverride: .automatic)
        let keyword = try utf8Range("def", in: output.text)
        #expect(output.syntax.contains { $0.range.location == keyword.location
            && $0.lightForeground == EditorThemePalette.light.colors.keyword })
    }

    @Test func themeAndSearchOverlayKeepSyntaxAndSelection() throws {
        let source = "fn main() {\n    // 한글 🦆\n    let message = \"IGNITE\";\n    let count = 42;\n}\n"
        let content = try highlighter().highlight(.init(text: source, firstLine: 680, matchLine: 682,
            highlight: try utf8Range("IGNITE", in: source)), filename: "preview.rs", languageOverride: .automatic)
        let view = SearchCodePreviewView(frame: .init(x: 0, y: 0, width: 850, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        let selection = NSRange(location: 3, length: 4)
        for (name, palette) in [(NSAppearance.Name.aqua, EditorThemePalette.light), (.darkAqua, .dark)] {
            view.appearance = NSAppearance(named: name)
            view.apply(content)
            #expect(try foreground("fn", in: view) == palette.colors.keyword)
            #expect(try foreground("//", in: view) == palette.colors.comment)
            #expect(try foreground("42", in: view) == palette.colors.number)
            #expect(try foreground("IGNITE", in: view) == 0)
            let match = (view.textView.string as NSString).range(of: "IGNITE")
            #expect(view.textView.textStorage?.attribute(.backgroundColor, at: match.location, effectiveRange: nil) != nil)
            view.textView.setSelectedRange(selection)
            view.apply(content)
            #expect(view.textView.selectedRange() == selection)
            #expect(view.textView.string == source)
            #expect(!view.textView.isEditable)
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_SEARCH_SYNTAX_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                window.makeKeyAndOrderFront(nil); view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent("search-preview-\(palette == .light ? "light" : "dark").png"))
            }
        }
    }

    @Test func malformedByteRangesDoNotSplitEmojiOrCrash() throws {
        let source = "🦆 한글 plain"
        let view = SearchCodePreviewView(frame: .zero)
        view.appearance = NSAppearance(named: .aqua)
        let bad = [SearchUTF8Range(location: 1, length: 1), .init(location: -1, length: 2),
                   .init(location: Int.max, length: 1), .init(location: 0, length: Int.max)]
        view.apply(.init(text: source, firstLine: 1, matchLine: 1, highlight: .init(location: -1, length: 0),
            syntax: bad.map { .init(range: $0, lightForeground: 0xFF0000, darkForeground: 0x00FF00) }))
        #expect(view.textView.string == source)
        #expect(try foreground("🦆", in: view) == EditorThemePalette.light.colors.foreground)
    }

    @Test func canonicallyEquivalentPreviewsReplaceTheirExactSourceBytes() throws {
        let view = SearchCodePreviewView(frame: .zero)
        let lexer = try highlighter()
        for source in ["let café = \"IGNITE\"", "let cafe\u{301} = \"IGNITE\"", "let café = \"IGNITE\""] {
            let content = lexer.highlight(.init(text: source, firstLine: 1, matchLine: 1,
                highlight: try utf8Range("IGNITE", in: source)), filename: "preview.rs", languageOverride: .automatic)
            view.apply(content)
            #expect(view.textView.string.utf8.elementsEqual(source.utf8))
            #expect(view.textView.textStorage?.length == source.utf16.count)
            #expect(try foreground("IGNITE", in: view) == 0)
        }
    }

    @Test(arguments: [false, true])
    func actualSearchColorsClosedFilesAndManualUntitledLanguageWithoutEditingSource(closed: Bool) async throws {
        _ = NSApplication.shared
        let registry = try LanguageManifestLoader().loadBundled()
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        let folder = FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
            markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view,
            searchUseCase: search, folderSearchUseCase: folder,
            searchPreviewHighlighter: ScintillaSearchPreviewHighlighter(registry: registry), automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-colored-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { controller.close(); editor.invalidate(); try? FileManager.default.removeItem(at: directory) }
        let source = "fn main() {\n    let message = \"IGNITE\"; // 한글 🦆\n}\n"
        let file = directory.appendingPathComponent("preview.rs")
        let native = try #require(editor.activeScintillaView)
        if closed { try Data(source.utf8).write(to: file) }
        else {
            native.insertCommittedText(source)
            let tab = try #require(workspace.snapshot().tabs.first(where: \.isActive)?.id)
            _ = await workspace.setLanguageOverride(.manual(.init(rawValue: "rust")), for: tab)
        }
        await workspace.waitForPendingPersistence()
        let before = workspace.snapshot().tabs, bytes = native.contentUTF8, lexer = native.lexerName, undo = native.canUndo
        controller.performReplaceInFiles()
        let panel = controller.searchExperience.multiPanel
        if closed { panel.selectFolder(directory) }
        let content = try #require(panel.window?.contentView)
        let preview = try #require(views(content).compactMap { $0 as? SearchCodePreviewView }.first)
        preview.appearance = NSAppearance(named: .aqua)
        panel.setQuery(.init(pattern: "IGNITE"))
        try await wait { preview.textView.string.contains("fn main") && (try? self.foreground("fn", in: preview)) == EditorThemePalette.light.colors.keyword }
        #expect(workspace.snapshot().tabs == before)
        #expect(native.contentUTF8 == bytes)
        #expect(native.lexerName == lexer)
        #expect(native.canUndo == undo)
        if closed { #expect(try Data(contentsOf: file) == Data(source.utf8)) }
        else { native.undo(); #expect(native.contentUTF8.isEmpty) }
    }
}
