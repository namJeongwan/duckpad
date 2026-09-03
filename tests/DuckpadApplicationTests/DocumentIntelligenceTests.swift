import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

@MainActor
private final class DocumentIntelligenceEditorSpy: DocumentIntelligenceEditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    var buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 3)
    var data = Data()
    var caret = 0
    var languageID = LanguageID.plainText
    var contextID = DocumentIntelligenceContextID()
    var captureCount = 0
    var presentedItems: [String] = []
    var presentedPrefixByteCount = 0
    var allowPresentation = true
    var selectedRange: SearchUTF8Range?

    var activeDocumentIntelligenceBuffer: EditorBufferDescriptor? { buffer }
    var activeDocumentIntelligenceByteLength: Int { data.count }

    func captureDocumentIntelligence(maximumBytes: Int) -> DocumentIntelligenceCapture? {
        guard data.count <= maximumBytes else { return nil }
        captureCount += 1
        return DocumentIntelligenceCapture(
            buffer: buffer,
            utf8: data,
            caretUTF8: caret,
            languageID: languageID,
            contextID: contextID
        )
    }

    func presentCompletionItems(
        _ items: [String],
        replacingPrefixByteCount: Int,
        expectedBuffer: EditorBufferDescriptor,
        expectedCaretUTF8: Int,
        expectedContextID: DocumentIntelligenceContextID
    ) -> Bool {
        guard allowPresentation, expectedBuffer == buffer, expectedCaretUTF8 == caret,
              expectedContextID == contextID else { return false }
        presentedItems = items
        presentedPrefixByteCount = replacingPrefixByteCount
        return true
    }

    func cancelCompletion() {}
    func selectAndReveal(_ range: SearchUTF8Range) { selectedRange = range }
    func display(_ buffer: EditorBufferDescriptor) {}
    func install(_ snapshot: EditorTextSnapshot) {}
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? { nil }
    func retire(bufferID: BufferID) {}
    func setInputEnabled(_ isEnabled: Bool) {}
    func focus() {}
    func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? { nil }
    func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? { nil }
    func acknowledgeRecoverySnapshot(_ snapshot: EditorRecoverySnapshot) {}
    func installRecovery(_ snapshot: EditorRecoverySnapshot) {}
}

@Test func completionCollectsUnicodeDocumentWordsAndSupplementalKeywords() {
    let text = "alpha alphabet Alpine 한글단어 한글함수\nalp"
    let capture = DocumentIntelligenceCapture(
        buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 1),
        utf8: Data(text.utf8),
        caretUTF8: text.utf8.count,
        languageID: .plainText,
        contextID: .init()
    )
    let result = DocumentIntelligenceAnalyzer.completion(
        in: capture,
        supplementalTerms: ["align allocate"]
    )

    #expect(result?.prefix == "alp")
    #expect(result?.prefixByteCount == 3)
    #expect(result?.items == ["alpha", "alphabet", "Alpine"])

    let koreanText = "한글단어 한글함수 한"
    let korean = DocumentIntelligenceAnalyzer.completion(in: .init(
        buffer: capture.buffer,
        utf8: Data(koreanText.utf8),
        caretUTF8: koreanText.utf8.count,
        languageID: .plainText,
        contextID: .init()
    ))
    #expect(korean?.prefix == "한")
    #expect(korean?.prefixByteCount == 3)
    #expect(Set(korean?.items ?? []) == Set(["한글단어", "한글함수"]))
}

@Test func symbolOutlineFindsDeclarationsWithExactUTF8Ranges() {
    let text = "// 머리🙂\npublic final class Duck {\n  func swim(speed: Int) {}\n  let 이름 = \"duck\"\n}\n"
    let capture = DocumentIntelligenceCapture(
        buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 2),
        utf8: Data(text.utf8),
        caretUTF8: 0,
        languageID: LanguageID(rawValue: "swift"),
        contextID: .init()
    )
    let symbols = DocumentIntelligenceAnalyzer.symbols(in: capture)

    #expect(symbols.map(\.name) == ["Duck", "swim", "이름"])
    #expect(symbols.map(\.kind) == [.type, .function, .property])
    #expect(symbols.map(\.line) == [2, 3, 4])
    for symbol in symbols {
        let lower = text.utf8.index(text.utf8.startIndex, offsetBy: symbol.range.location)
        let upper = text.utf8.index(lower, offsetBy: symbol.range.length)
        #expect(String(decoding: text.utf8[lower..<upper], as: UTF8.self) == symbol.name)
    }
}

@Test func symbolOutlineStreamsLFCRLFAndCROffsets() {
    let text = "머리🙂\rfunc one() {}\r\nfunc 둘() {}\nfunc three() {}"
    let capture = DocumentIntelligenceCapture(
        buffer: .init(bufferID: BufferID(), revision: 0),
        utf8: Data(text.utf8), caretUTF8: 0,
        languageID: LanguageID(rawValue: "swift"), contextID: .init()
    )
    let symbols = DocumentIntelligenceAnalyzer.symbols(in: capture)

    #expect(symbols.map(\.name) == ["one", "둘", "three"])
    #expect(symbols.map(\.line) == [2, 3, 4])
    for symbol in symbols {
        let lower = text.utf8.index(text.utf8.startIndex, offsetBy: symbol.range.location)
        let upper = text.utf8.index(lower, offsetBy: symbol.range.length)
        #expect(String(decoding: text.utf8[lower..<upper], as: UTF8.self) == symbol.name)
    }
}

@Test func adversarialCompletionAndOutlineRetainOnlyBoundedResults() {
    let maximum = DocumentIntelligenceAnalyzer.maximumInputBytes
    var text = ""
    text.reserveCapacity(maximum)
    var value = 0
    while text.utf8.count < maximum - 16 {
        text += String(format: "a%07x ", value)
        value += 1
    }
    text += "a"
    let capture = DocumentIntelligenceCapture(
        buffer: .init(bufferID: BufferID(), revision: 0),
        utf8: Data(text.utf8), caretUTF8: text.utf8.count,
        languageID: .plainText, contextID: .init()
    )

    let completion = DocumentIntelligenceAnalyzer.completion(in: capture)
    #expect(completion?.items.count == DocumentIntelligenceAnalyzer.maximumCompletionItems)
    #expect(completion?.items == completion?.items.sorted())

    let line = "func item() {}\n"
    let outlinedText = String(repeating: line, count: maximum / line.utf8.count)
    let outlineCapture = DocumentIntelligenceCapture(
        buffer: capture.buffer, utf8: Data(outlinedText.utf8), caretUTF8: 0,
        languageID: LanguageID(rawValue: "swift"), contextID: .init()
    )
    #expect(
        DocumentIntelligenceAnalyzer.symbols(in: outlineCapture).count
            == DocumentIntelligenceAnalyzer.maximumSymbolItems
    )

    let noSymbolCapture = DocumentIntelligenceCapture(
        buffer: capture.buffer,
        utf8: Data(String(repeating: "a\n", count: maximum / 2).utf8),
        caretUTF8: 0, languageID: .plainText, contextID: .init()
    )
    let clock = ContinuousClock()
    let noSymbolStart = clock.now
    #expect(DocumentIntelligenceAnalyzer.symbols(in: noSymbolCapture).isEmpty)
    #expect(noSymbolStart.duration(to: clock.now) < .seconds(3))

    let oversized = DocumentIntelligenceCapture(
        buffer: capture.buffer, utf8: Data(repeating: 0x61, count: maximum + 1),
        caretUTF8: 0, languageID: .plainText, contextID: .init()
    )
    #expect(DocumentIntelligenceAnalyzer.completion(in: oversized) == nil)
    #expect(DocumentIntelligenceAnalyzer.symbols(in: oversized).isEmpty)
}

@Test func markdownHeadingsAreLanguageScopedAndBounded() {
    let text = "# First\n## Second\n# comment"
    let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    let markdown = DocumentIntelligenceCapture(
        buffer: buffer, utf8: Data(text.utf8), caretUTF8: 0,
        languageID: LanguageID(rawValue: "markdown"), contextID: .init()
    )
    #expect(DocumentIntelligenceAnalyzer.symbols(in: markdown, maximumItems: 2).map(\.name) == ["First", "Second"])
    let python = DocumentIntelligenceCapture(
        buffer: buffer, utf8: Data(text.utf8), caretUTF8: 0,
        languageID: LanguageID(rawValue: "python"), contextID: .init()
    )
    #expect(DocumentIntelligenceAnalyzer.symbols(in: python).isEmpty)

    let structuredText = "[network]\n\"timeout\": 30"
    let ini = DocumentIntelligenceCapture(
        buffer: buffer, utf8: Data(structuredText.utf8), caretUTF8: 0,
        languageID: LanguageID(rawValue: "ini"), contextID: .init()
    )
    #expect(DocumentIntelligenceAnalyzer.symbols(in: ini).map(\.name) == ["network"])
    let json = DocumentIntelligenceCapture(
        buffer: buffer, utf8: Data(structuredText.utf8), caretUTF8: 0,
        languageID: LanguageID(rawValue: "json"), contextID: .init()
    )
    #expect(DocumentIntelligenceAnalyzer.symbols(in: json).map(\.name) == ["timeout"])
    let structuredPython = DocumentIntelligenceCapture(
        buffer: buffer, utf8: Data(structuredText.utf8), caretUTF8: 0,
        languageID: LanguageID(rawValue: "python"), contextID: .init()
    )
    #expect(DocumentIntelligenceAnalyzer.symbols(in: structuredPython).isEmpty)

    let uncommonWhitespace = "\u{00A0}#Compact\n\u{3000}func unicodeSpace() {}"
    let whitespaceCapture = DocumentIntelligenceCapture(
        buffer: buffer, utf8: Data(uncommonWhitespace.utf8), caretUTF8: 0,
        languageID: LanguageID(rawValue: "markdown"), contextID: .init()
    )
    #expect(
        DocumentIntelligenceAnalyzer.symbols(in: whitespaceCapture).map(\.name)
            == ["Compact", "unicodeSpace"]
    )
}

@Test @MainActor func useCaseRejectsLargeAndStaleRequestsWithoutPresentation() async {
    let editor = DocumentIntelligenceEditorSpy()
    editor.data = Data(repeating: 0x61, count: 2_048)
    editor.caret = editor.data.count
    let bounded = DocumentIntelligenceUseCase(editor: editor, maximumDocumentBytes: 1_024)
    #expect(await bounded.complete() == .overBudget(actualBytes: 2_048, maximumBytes: 1_024))
    #expect(editor.captureCount == 0)

    editor.data = Data("alpha alp".utf8)
    editor.caret = editor.data.count
    editor.allowPresentation = false
    let ordinary = DocumentIntelligenceUseCase(editor: editor, maximumDocumentBytes: 4_096)
    #expect(await ordinary.complete() == .stale)
    #expect(editor.presentedItems.isEmpty)
}

@Test @MainActor func useCaseRevealsOnlyTheCapturedBufferRevision() async throws {
    let editor = DocumentIntelligenceEditorSpy()
    let text = "func paddle() {}"
    editor.data = Data(text.utf8)
    editor.languageID = LanguageID(rawValue: "swift")
    let useCase = DocumentIntelligenceUseCase(editor: editor)
    guard case .ready(let outline) = await useCase.outline() else {
        Issue.record("outline unavailable")
        return
    }
    let symbol = try #require(outline.symbols.first)
    #expect(useCase.reveal(symbol, in: outline))
    #expect(editor.selectedRange == symbol.range)

    editor.buffer = EditorBufferDescriptor(bufferID: outline.buffer.bufferID, revision: 4)
    editor.selectedRange = nil
    #expect(!useCase.reveal(symbol, in: outline))
    #expect(editor.selectedRange == nil)
}
