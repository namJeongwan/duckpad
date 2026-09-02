import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadScintillaBridge
import Foundation
import Testing

@Suite(.serialized)
struct LanguageEditorAdapterTests {
    @MainActor
    private func hostedView() -> (NSWindow, DPScintillaEditorView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = DPScintillaEditorView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        return (window, view)
    }

    @Test @MainActor
    func everyBundledLexerResolvesInVendoredLexilla() throws {
        let registry = try LanguageManifestLoader().loadBundled()
        let unresolved = Set(registry.definitions.map(\.lexerName)).filter {
            !DPScintillaEditorView.supportsLexerNamed($0)
        }
        #expect(unresolved.isEmpty)
    }

    @Test @MainActor
    func representativeLexersStyleKeywordsStringsCommentsAndUTF8() throws {
        for fixture in [
            ("cpp", ["int return"], "int main() { const char *s = \"🦆\"; return 1; } // 한글", 5, 4, 6, 2),
            ("python", ["def return"], "def duck():\n    value = 1\n    return \"🦆\" # 한글", 5, 2, 3, 1),
            ("rust", ["fn let"], "fn main() { let n = 1; let duck = \"🦆\"; } // 한글", 6, 5, 13, 2),
        ] {
            let (_, view) = hostedView()
            try view.loadUTF8(Data(fixture.2.utf8), revision: 7)
            #expect(view.applyLexerNamed(fixture.0, keywords: fixture.1, tabWidth: 4, useTabs: false, folding: true, braceMatching: true, maximumStyleBytes: 1_000_000))
            func offset(_ token: String) -> UInt {
                let bytes = Array(fixture.2.utf8)
                let needle = Array(token.utf8)
                for index in bytes.indices where index + needle.count <= bytes.count {
                    if Array(bytes[index..<(index + needle.count)]) == needle { return UInt(index) }
                }
                Issue.record("missing fixture token \(token)")
                return 0
            }
            #expect(view.style(atUTF8Position: 0) == fixture.3)
            #expect(view.style(atUTF8Position: offset("1")) == fixture.4)
            #expect(view.style(atUTF8Position: offset("\"")) == fixture.5)
            #expect(view.style(atUTF8Position: offset(fixture.0 == "python" ? "#" : "//")) == fixture.6)
            let emojiOffset = fixture.2.utf8.distance(from: fixture.2.utf8.startIndex, to: fixture.2.utf8.firstIndex(of: 0xF0)!)
            #expect(view.style(atUTF8Position: UInt(emojiOffset)) >= 0)
        }
    }

    @Test @MainActor
    func foldBraceAndIndentCapabilitiesAreAppliedAndCanBeDisabled() throws {
        let hosted = hostedView()
        let view = hosted.1
        let source = "한글🦆 int main() {\n  if (true) {\n    return 1;\n  }\n}\n"
        try view.loadUTF8(Data(source.utf8), revision: 1)
        #expect(view.applyLexerNamed("cpp", keywords: ["int if return true"], tabWidth: 8, useTabs: true, folding: true, braceMatching: true, maximumStyleBytes: 1_000_000))
        #expect(view.configuredTabWidth == 8)
        #expect(view.configuredUseTabs)
        #expect(view.configuredFoldingEnabled)
        #expect(view.configuredBraceMatchingEnabled)
        #expect((view.foldLevel(atLine: 0) & 0x2000) != 0)
        let expanded = view.isFoldExpanded(atLine: 0)
        view.toggleFold(atLine: 0)
        #expect(view.isFoldExpanded(atLine: 0) != expanded)
        let brace = Array(source.utf8).firstIndex(of: Character("{").asciiValue!)!
        view.setPrimarySelectionUTF8Range(NSRange(location: brace + 1, length: 0))
        view.updateBraceHighlight()
        #expect(view.highlightedBraceUTF8Position == brace)
        #expect(view.matchingBraceUTF8Position > view.highlightedBraceUTF8Position)
        #expect(view.foregroundColor(forStyle: 34) != view.foregroundColor(forStyle: 35))

        let (_, badBraceView) = hostedView()
        let unmatched = "한글🦆 {"
        try badBraceView.loadUTF8(Data(unmatched.utf8), revision: 2)
        #expect(badBraceView.applyLexerNamed("cpp", keywords: ["int"], tabWidth: 4, useTabs: false, folding: true, braceMatching: true, maximumStyleBytes: 1_000_000))
        let unmatchedBrace = Array(unmatched.utf8).firstIndex(of: Character("{").asciiValue!)!
        badBraceView.setPrimarySelectionUTF8Range(NSRange(location: unmatchedBrace + 1, length: 0))
        badBraceView.updateBraceHighlight()
        #expect(badBraceView.badBraceUTF8Position == unmatchedBrace)

        #expect(view.applyLexerNamed("null", keywords: [], tabWidth: 4, useTabs: false, folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
        #expect(!view.configuredFoldingEnabled)
        #expect(!view.configuredBraceMatchingEnabled)
        view.updateBraceHighlight()
        #expect(view.highlightedBraceUTF8Position == -1)
        #expect(view.matchingBraceUTF8Position == -1)
    }

    @Test @MainActor
    func themeAndLanguageChangesDoNotMutateTextRevisionOrUndo() throws {
        let (_, view) = hostedView()
        try view.loadUTF8(Data("int duck = 1;".utf8), revision: 4)
        view.resetInstrumentation()
        #expect(view.applyLexerNamed("cpp", keywords: ["int"], tabWidth: 4, useTabs: false, folding: true, braceMatching: true, maximumStyleBytes: 1_000_000))
        let before = view.contentUTF8
        let revision = view.revision
        let canUndo = view.canUndo
        let snapshotReads = view.snapshotReadCount
        view.apply(.dark)
        view.apply(.highContrastLight)
        #expect(view.revision == revision)
        #expect(view.canUndo == canUndo)
        #expect(view.snapshotReadCount == snapshotReads)
        #expect(view.contentUTF8 == before)
    }

    @Test @MainActor
    func largeDocumentFallsBackWithoutSnapshotRead() throws {
        let (_, view) = hostedView()
        let bytes = Data(repeating: 0x61, count: 50 * 1_024 * 1_024)
        try view.loadUTF8(bytes, revision: 2)
        view.resetInstrumentation()
        #expect(view.applyLexerNamed("cpp", keywords: ["int"], tabWidth: 4, useTabs: false, folding: true, braceMatching: true, maximumStyleBytes: 16 * 1_024 * 1_024))
        #expect(view.languageStylingFallback)
        #expect(view.lexerName == "null")
        #expect(view.snapshotReadCount == 0)
        #expect(view.synchronouslyStyledByteCount == 0)
        #expect(!view.configuredFoldingEnabled)
        #expect(!view.configuredBraceMatchingEnabled)
        #expect(view.revision == 2)
    }

    @Test @MainActor
    func multilineCommentToggleIsBoundedAndOneUndoRestoresExactText() throws {
        let (_, view) = hostedView()
        let original = "  first\r\n\r\n\t한글\r\nlast"
        try view.loadUTF8(Data(original.utf8), revision: 0)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: original.utf8.count))
        #expect(view.toggleLineComments(withPrefixUTF8: Data("//".utf8)))
        let changed = String(data: view.contentUTF8, encoding: .utf8)!
        #expect(changed == "  //first\r\n\r\n\t//한글\r\n//last")
        #expect(view.commentCommandInspectedByteCount < 64)
        view.undo()
        #expect(String(data: view.contentUTF8, encoding: .utf8) == original)
    }

    @Test @MainActor
    func commentToggleAdvancesWorkspaceRecoveryAndGroupedUndoRestoresIt() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        #expect(await workspace.start() == .saved)
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        let buffer = try #require(workspace.snapshot().activeBuffer)
        adapter.display(buffer)
        let original = "one\n  two\n한글"
        adapter.install(EditorTextSnapshot(bufferID: buffer.bufferID, revision: 0, text: original))
        adapter.activeScintillaView?.setPrimarySelectionUTF8Range(NSRange(location: 0, length: original.utf8.count))
        let commented = adapter.toggleLineComment(prefix: "//")
        guard case .accepted(let commentedRevision) = commented else {
            Issue.record("comment command rejected")
            return
        }
        #expect(commentedRevision == 3)
        #expect(String(data: adapter.recoverySnapshot(for: buffer.bufferID)!.utf8, encoding: .utf8) == "//one\n  //two\n//한글")
        adapter.activeScintillaView?.undo()
        let restored = try #require(adapter.recoverySnapshot(for: buffer.bufferID))
        #expect(String(data: restored.utf8, encoding: .utf8) == original)
        #expect(restored.revision > commentedRevision)
        _ = binding
    }
}
