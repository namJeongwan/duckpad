import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadPresentation
import Foundation

@MainActor
private final class TimedFormatter: DocumentFormatting {
    let engine = BundledPrettierFormatter()
    var milliseconds = 0.0
    func format(_ request: FormattingRequest) async throws -> String {
        let start = ContinuousClock.now
        let output = try await engine.format(request)
        milliseconds = FormattingBenchmark.milliseconds(start.duration(to: .now))
        return output
    }
}

@MainActor
enum FormattingBenchmark {
    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    static func run(path: String, language: String = "json") async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let input = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-format-benchmark-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.\(language)")
        try input.write(to: url)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let engine = TimedFormatter()
        let formatting = DocumentFormattingUseCase(workspace: workspace, editor: editor, formatter: engine)
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("access.json")))
        files.formattingUseCase = formatting
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: LocalMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view,
            fileUseCase: files, formattingUseCase: formatting)
        defer { controller.close(); editor.invalidate() }
        await controller.waitForStartup()
        guard case .opened = await files.open(url), let view = editor.activeScintillaView else { throw FormattingFailure.unavailable }
        let definition = try LanguageManifestLoader().loadBundled().require(.init(rawValue: language))
        guard editor.applyLanguage(.init(languageID: definition.id, lexerName: definition.lexerName,
            keywords: definition.keywordLists, comments: definition.capabilities.comments, indentation: definition.capabilities.indentation,
            folding: definition.capabilities.supportsFolding,
            braceMatching: definition.capabilities.supportsBraceMatching)) else { throw FormattingFailure.unavailable }
        for pass in 0..<4 {
            engine.milliseconds = 0
            let start = ContinuousClock.now
            _ = try await formatting.format()
            let total = milliseconds(start.duration(to: .now))
            print("FORMAT language=\(language) pass=\(pass) bytes=\(input.count) total_ms=\(total) engine_ms=\(engine.milliseconds)")
            if pass < 3 {
                let undo = ContinuousClock.now
                autoreleasepool { view.undo() }
                guard view.contentUTF8 == input else { throw FormattingFailure.unavailable }
                print("UNDO pass=\(pass) total_ms=\(milliseconds(undo.duration(to: .now)))")
            }
        }
        engine.milliseconds = 0
        let unchanged = ContinuousClock.now
        _ = try await formatting.format()
        print("UNCHANGED total_ms=\(milliseconds(unchanged.duration(to: .now))) engine_ms=\(engine.milliseconds)")
        let output = view.contentUTF8
        // Bypass the unchanged-revision shortcut to verify actual engine idempotence.
        let repeated = try await engine.engine.format(.init(text: String(decoding: output, as: UTF8.self), parser: language))
        guard Data(repeated.utf8) == output,
              let context = workspace.activeFileContext(),
              try editor.recoveryCapture(for: context.buffer.bufferID)?.materializedSnapshot().utf8 == output else {
            throw FormattingFailure.unavailable
        }
        print("VERIFIED undo_exact=true engine_idempotent=true recovery_exact=true output_bytes=\(output.count)")
    }
}
