import DuckpadApplication
import Foundation
import UniformTypeIdentifiers
import WebKit

@MainActor
final class MarkdownEditorResourceLoader: NSObject, WKURLSchemeHandler {
    private let reader: (any PreviewResourceReading)?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(reader: (any PreviewResourceReading)?) { self.reader = reader }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let request = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        if request.host == "assets",
           let root = DuckpadEditorResources.bundle.url(forResource: "MarkdownEditor", withExtension: nil) {
            let file = root.appendingPathComponent(request.path).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                  ["js", "css", "woff2", "woff", "ttf"].contains(file.pathExtension), let data = try? Data(contentsOf: file) else {
                task.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            let mime = ["js": "text/javascript", "css": "text/css", "woff2": "font/woff2", "woff": "font/woff", "ttf": "font/ttf"][file.pathExtension]!
            task.didReceive(URLResponse(url: request, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data); task.didFinish(); return
        }
        guard request.host == "local", let reader,
              let value = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let file = URL(string: value), file.isFileURL,
              let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let id = ObjectIdentifier(task)
        tasks[id] = Task { [weak self] in
            var stream: (any PreviewResourceStream)?
            do {
                let resource = try await reader.open(file); stream = resource
                try Task.checkCancellation()
                task.didReceive(URLResponse(url: request, mimeType: type.preferredMIMEType, expectedContentLength: -1, textEncodingName: nil))
                var count = 0
                while true {
                    let chunk = try await resource.read(); try Task.checkCancellation()
                    if chunk.isEmpty { break }
                    count += chunk.count
                    guard count <= 32 * 1_024 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
                    task.didReceive(chunk)
                }
                task.didFinish()
            } catch {
                if !Task.isCancelled { task.didFailWithError(error) }
            }
            await stream?.close(); self?.tasks[id] = nil
        }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { tasks.removeValue(forKey: ObjectIdentifier(task))?.cancel() }
    func invalidate() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
}
