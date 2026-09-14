import DuckpadApplication
import Foundation
import WebKit

@MainActor
final class PrettierWebRuntime: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private let timeout: Duration
    private var continuation: CheckedContinuation<String, Error>?
    private var timer: Task<Void, Never>?
    private var activeID: UUID?
    private var pendingRequest: FormattingRequest?
    private var isReady = false
    private(set) var isEvaluating = false
    var isReusable: Bool { webView != nil }

    init(script: String, timeout: Duration) {
        self.timeout = timeout
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView?.navigationDelegate = self
    }

    func format(_ request: FormattingRequest, id: UUID) async throws -> String {
        try Task.checkCancellation()
        guard continuation == nil else { throw FormattingFailure.busy }
        guard webView != nil else { throw FormattingFailure.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            activeID = id
            pendingRequest = request
            timer = Task { @MainActor [weak self, timeout] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.finish(.failure(FormattingFailure.timedOut), id: id, discard: true)
            }
            if isReady {
                evaluate(request, id: id)
            } else {
                webView?.loadHTMLString("<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'\">", baseURL: nil)
            }
        }
    }

    func cancel(id: UUID) { finish(.failure(CancellationError()), id: id, discard: true) }

    func invalidate() {
        if let activeID { finish(.failure(FormattingFailure.unavailable), id: activeID, discard: true) }
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        isReady = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        if let request = pendingRequest, let activeID { evaluate(request, id: activeID) }
    }

    private func evaluate(_ request: FormattingRequest, id: UUID) {
        let settings = request.settings
        let options: [String: Any] = [
            "parser": request.parser, "tabWidth": min(max(settings.tabWidth, 1), 16),
            "printWidth": min(max(settings.printWidth, 40), 320), "useTabs": settings.useTabs,
            "singleQuote": settings.singleQuote, "semi": settings.semicolons,
            "sqlDialect": settings.sqlDialect.rawValue,
        ]
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, self.activeID == id else { return }
            self.isEvaluating = true
            defer { self.isEvaluating = false }
            do {
                let value = try await webView.callAsyncJavaScript("return await duckpadFormat(text, options);", arguments: ["text": request.text, "options": options], in: nil, contentWorld: .page)
                guard let text = value as? String else {
                    self.finish(.failure(FormattingFailure.unavailable), id: id, discard: true); return
                }
                guard text.utf8.count <= 4 * BundledPrettierFormatter.maximumInputBytes else {
                    self.finish(.failure(FormattingFailure.tooLarge), id: id, discard: true); return
                }
                self.finish(.success(text), id: id)
            } catch {
                let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                // Keep the diagnostic and location, omitting Prettier's source code frame.
                let summary = detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                self.finish(.failure(FormattingFailure.invalidSyntax(String(summary.prefix(300)))), id: id)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { invalidate() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { invalidate() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { invalidate() }

    private func finish(_ result: Result<String, Error>, id: UUID, discard: Bool = false) {
        // A late cancellation or completion must never affect the next request.
        guard activeID == id, let continuation else { return }
        self.continuation = nil
        activeID = nil
        pendingRequest = nil
        timer?.cancel()
        timer = nil
        if discard { invalidate() }
        continuation.resume(with: result)
    }
}
