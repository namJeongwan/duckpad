import DuckpadInfrastructure
import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadScintillaBridge
@testable import DuckpadPresentation
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct MarkdownPreviewIntegrationTests {
    @Test func previewDebouncesReadsTracksTypingAndStopsWhenClosed() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: PreviewIntegrationStore())
        let adapter = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: adapter,
                                                  editorView: adapter.view, automaticallyStarts: false)
        defer { controller.close(); adapter.invalidate() }
        controller.start()
        await controller.waitForStartup()
        let view = try #require(adapter.activeScintillaView)
        view.insertCommittedText("# Initial")
        view.resetInstrumentation()
        try await Task.sleep(for: .milliseconds(400))
        #expect(view.snapshotReadCount == 0)
        controller.performToggleMarkdownPreview()
        let panel = try #require(descendants(controller.window!.contentView!).compactMap { $0 as? MarkdownPreviewPanel }.first)
        let web = try #require(panel.subviews.compactMap { $0 as? WKWebView }.first)
        #expect(view.snapshotReadCount == 0)
        try await waitForHeading("Initial", in: web)
        #expect(panel.bounds.width < panel.superview!.bounds.width * 0.8)
        #expect(controller.editorGroupWorkspace.bounds.width > 200)
        #expect(view.snapshotReadCount == 0)

        view.setPrimarySelectionUTF8Range(NSRange(location: 2, length: 0))
        try await Task.sleep(for: .milliseconds(400))
        #expect(view.snapshotReadCount == 0)
        view.setPrimarySelectionUTF8Range(NSRange(location: 2, length: 7))
        view.insertCommittedText("Latest")
        try await waitForHeading("Latest", in: web)
        #expect(view.snapshotReadCount == 0)
        #expect(view.contentUTF8 == Data("# Latest".utf8))

        if let path = ProcessInfo.processInfo.environment["DUCKPAD_MARKDOWN_SNAPSHOT"] {
            let bitmap = try await web.takeSnapshot(configuration: nil)
            let data = try #require(bitmap.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path))
        }
        controller.performToggleMarkdownPreview()
        view.resetInstrumentation()
        view.insertCommittedText("!")
        try await Task.sleep(for: .milliseconds(400))
        #expect(view.snapshotReadCount == 0)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func waitForHeading(_ expected: String, in web: WKWebView) async throws {
        for _ in 0..<150 {
            let heading = try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent") as? String
            if heading == expected { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        Issue.record("Preview did not render the latest heading: \(expected)")
    }
}

private actor PreviewIntegrationStore: SessionStore {
    private var value: StoredSession?
    func loadSession() async throws(SessionStoreError) -> StoredSession? { value }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        value = StoredSession(session: session, generation: generation)
        return .committed
    }
}
