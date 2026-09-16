import Foundation
import UniformTypeIdentifiers
import WebKit

/// WebKit can only request bundled assets or image files. The OS still enforces
/// the application's security-scoped folder grants for local image access.
@MainActor
final class MarkdownPreviewResourceLoader: NSObject, WKURLSchemeHandler {
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let request = urlSchemeTask.request.url, let file = fileURL(for: request) else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? (file.pathExtension == "js" ? "text/javascript" : "application/octet-stream")
        tasks[id] = Task { [weak self] in
            do {
                let handle = try await Task.detached(priority: .utility) { try FileHandle(forReadingFrom: file) }.value
                defer { try? handle.close() }
                try Task.checkCancellation()
                urlSchemeTask.didReceive(URLResponse(url: request, mimeType: mime, expectedContentLength: -1, textEncodingName: nil))
                while true {
                    let chunk = try await Task.detached(priority: .utility) { try handle.read(upToCount: 64 * 1024) }.value
                    try Task.checkCancellation()
                    guard let chunk, !chunk.isEmpty else { break }
                    urlSchemeTask.didReceive(chunk)
                }
                urlSchemeTask.didFinish()
            } catch is CancellationError {
                // WebKit has already stopped this task; never send another callback.
            } catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
            self?.tasks[id] = nil
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    func invalidate() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func fileURL(for request: URL) -> URL? {
        if request.host == "assets", let root = DuckpadPresentationResources.bundle?.url(forResource: "MarkdownPreview", withExtension: nil) {
            let file = root.appendingPathComponent(request.path).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { return nil }
            return file
        }
        guard request.host == "local",
              let raw = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let file = URL(string: raw), file.isFileURL,
              UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true else { return nil }
        return file
    }
}
