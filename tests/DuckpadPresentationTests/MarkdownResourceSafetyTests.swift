import DuckpadInfrastructure
import DuckpadApplication
import Darwin
import Foundation
@testable import DuckpadPresentation
import Testing
import WebKit

@MainActor private final class ResourceTask: NSObject, @preconcurrency WKURLSchemeTask {
    let request: URLRequest
    var failure: Error?
    var finished = false
    var receivedResponse = false
    init(file: URL) {
        var url = URLComponents(string: "duckpad-preview://local/")!
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
        func remember(_ urls: [URL]) {}
        func acquire() -> [URL] { outstanding += 1; return [URL(fileURLWithPath: "/test-image-grant")] }
        func release(_ urls: [URL]) { outstanding -= urls.count }
    }

    @Test @MainActor func reloadingAndClosingReleaseEveryImageGrant() {
        let grants = Grants()
        let panel = MarkdownPreviewPanel(frame: .zero, resourceReader: LocalPreviewResourceReader(), imageAccess: grants)
        #expect(grants.outstanding == 1)
        panel.reloadImageAccess()
        #expect(grants.outstanding == 1)
        panel.invalidate()
        panel.invalidate()
        #expect(grants.outstanding == 0)
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
        let loader = MarkdownPreviewResourceLoader(reader: LocalPreviewResourceReader())
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
