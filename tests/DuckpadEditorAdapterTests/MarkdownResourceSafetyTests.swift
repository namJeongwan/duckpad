import DuckpadInfrastructure
import DuckpadApplication
import DuckpadDomain
import Darwin
import Foundation
@testable import DuckpadEditorAdapter
import AppKit
import Testing
import WebKit

@MainActor private final class ResourceTask: NSObject, @preconcurrency WKURLSchemeTask {
    let request: URLRequest
    var failure: Error?
    var finished = false
    var receivedResponse = false
    init(file: URL) {
        var url = URLComponents(string: "duckpad-editor://local/")!
        url.queryItems = [.init(name: "url", value: file.absoluteString)]
        request = URLRequest(url: url.url!)
    }
    func didReceive(_ response: URLResponse) { receivedResponse = true }
    func didReceive(_ data: Data) {}
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { failure = error }
}

@Suite(.serialized) struct MarkdownResourceSafetyTests {
    @MainActor private final class Grants: MarkdownImageAccess {
        var outstanding = 0
        var stored = [URL(fileURLWithPath: "/test-image-grant")]
        func remember(_ urls: [URL]) { stored += urls }
        func acquire() -> [URL] { outstanding += stored.count; return stored }
        func release(_ urls: [URL]) { outstanding -= urls.count }
    }

    @Test @MainActor func closingEditorReleasesEveryImageGrant() {
        let grants = Grants()
        _ = NSApplication.shared
        let panel = CodeMirrorEditorView(reader: LocalPreviewResourceReader(), imageAccess: grants)
        #expect(grants.outstanding == 1)
        panel.invalidate()
        panel.invalidate()
        #expect(grants.outstanding == 0)
    }

    @Test @MainActor func newlyRememberedImagesReacquireGrantsBeforeReloadAndReleaseOnce() async throws {
        _ = NSApplication.shared
        let grants = Grants()
        let panel = CodeMirrorEditorView(reader: LocalPreviewResourceReader(), imageAccess: grants)
        defer { panel.invalidate() }
        for _ in 0..<200 {
            if panel.ready { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.ready)
        _ = try await panel.webView.evaluateJavaScript("window.imageReloads=0;window.DuckpadEditor.reloadImages=()=>{window.imageReloads++};true")
        grants.remember([URL(fileURLWithPath: "/new-image-grant")])
        panel.reloadImageAccess()
        #expect(grants.outstanding == 2)
        for _ in 0..<100 {
            if try await panel.webView.evaluateJavaScript("window.imageReloads") as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await panel.webView.evaluateJavaScript("window.imageReloads") as? Int == 1)
        panel.invalidate(); panel.invalidate()
        #expect(grants.outstanding == 0)
        panel.reloadImageAccess()
        #expect(grants.outstanding == 0)
    }

    @Test @MainActor func repeatedMarkdownSplitCollapseReleasesClosedWebEditorsAndImageGrants() async throws {
        _ = NSApplication.shared
        let grants = Grants(), editor = ScintillaEditorAdapter(markdownImageAccess: grants)
        defer { editor.invalidate() }
        let descriptor = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        editor.install(.init(bufferID: descriptor.bufferID, revision: 0, text: "# Shared\n\nEnd"))
        editor.display(descriptor)
        #expect(editor.applyLanguage(.init(languageID: .init(rawValue: "markdown"), lexerName: "markdown", indentation: .init(), folding: false, braceMatching: false)))
        #expect(grants.outstanding == 1)
        for groupSplit in [false, true] {
            for _ in 0..<3 {
                if groupSplit {
                    editor.setEditorGroupOrientation(.sideBySide)
                    editor.assign(descriptor, from: .primary, to: .secondary, cloning: true)
                    editor.display(descriptor, in: .secondary)
                    editor.activateEditorGroup(.secondary)
                } else { editor.split(orientation: .sideBySide) }
                let native = try #require(groupSplit ? editor.activeScintillaView : editor.secondaryScintillaView)
                weak var closed = editor.markdownEditors.editor(for: native)
                #expect(closed != nil)
                #expect(grants.outstanding == 2)
                if groupSplit { editor.setEditorGroupOrientation(nil) } else { editor.closeSplit() }
                #expect(editor.markdownEditors.editor(for: native) == nil)
                #expect(grants.outstanding == 1)
                for _ in 0..<100 {
                    if closed == nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(closed == nil)
            }
        }
        #expect(editor.activeCodeMirrorEditor != nil)
        editor.invalidate()
        #expect(grants.outstanding == 0)
    }

    @Test(arguments: [false, true]) @MainActor func paneCompositionDrainsBeforeClosingItsWebEditor(groupSplit: Bool) async throws {
        _ = NSApplication.shared
        let grants = Grants(), editor = ScintillaEditorAdapter(markdownImageAccess: grants)
        editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        defer { editor.invalidate() }
        let descriptor = EditorBufferDescriptor(bufferID: BufferID(), revision: 0), source = "# Shared\n\nEnd"
        editor.install(.init(bufferID: descriptor.bufferID, revision: 0, text: source))
        editor.display(descriptor)
        #expect(editor.applyLanguage(.init(languageID: .init(rawValue: "markdown"), lexerName: "markdown", indentation: .init(), folding: false, braceMatching: false)))
        if groupSplit {
            editor.setEditorGroupOrientation(.sideBySide)
            editor.assign(descriptor, from: .primary, to: .secondary, cloning: true)
            editor.display(descriptor, in: .secondary)
            editor.activateEditorGroup(.secondary)
        } else { editor.split(orientation: .sideBySide) }
        let native = try #require(groupSplit ? editor.activeScintillaView : editor.secondaryScintillaView)
        let web = try #require(editor.markdownEditors.editor(for: native))
        for _ in 0..<200 {
            if (try? await web.webView.evaluateJavaScript("!!document.querySelector('.cm-editor')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.webView.evaluateJavaScript("window.DuckpadEditor.compositionStart();window.DuckpadEditor.dispatch({changes:{from:13,insert:' 한글'}});true")
        for _ in 0..<100 {
            if web.isComposing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(web.isComposing)
        if groupSplit { editor.setEditorGroupOrientation(nil) } else { editor.closeSplit() }
        #expect(editor.markdownEditors.editor(for: native) != nil)
        #expect(grants.outstanding == 2)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: descriptor.bufferID)?.text == source + " 한글")
        if groupSplit { editor.setEditorGroupOrientation(nil) } else { editor.closeSplit() }
        #expect(editor.markdownEditors.editor(for: native) == nil)
        #expect(grants.outstanding == 1)
        #expect(editor.snapshot(for: descriptor.bufferID)?.text == source + " 한글")
    }

    @Test @MainActor func imageFIFOIsRejectedBeforeSendingResponse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        #expect(mkfifo(file.path, 0o600) == 0)
        // Release a regressed blocking open without hanging the test process.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            let fd = open(file.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if fd >= 0 { close(fd) }
        }
        let loader = MarkdownEditorResourceLoader(reader: LocalPreviewResourceReader())
        let task = ResourceTask(file: file)
        let web = WKWebView()
        loader.webView(web, start: task)
        for _ in 0..<50 {
            if task.failure != nil || task.finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(task.failure != nil, "An image-named FIFO must fail without a writer")
        #expect(!task.receivedResponse)
        loader.invalidate()
    }
}
