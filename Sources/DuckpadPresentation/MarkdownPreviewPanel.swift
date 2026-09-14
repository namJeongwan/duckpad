import AppKit
import DuckpadApplication
import DuckpadLocalization
import WebKit

@MainActor
final class MarkdownPreviewPanel: NSView, WKNavigationDelegate {
    private let title = NSTextField(labelWithString: "")
    private let closeButton = StatusBarButton()
    private let webView: WKWebView
    private let loader = MarkdownPreviewResourceLoader()
    private let folderButton = StatusBarButton()
    private var folderGrants: [URL] = []
    private var ready = false
    private var invalidated = false
    private enum Input: Sendable { case source(String), capture(EditorRecoveryCapture) }
    private struct Request {
        let generation: UInt64
        let input: Input
        let documentURL: URL?
        let plain: Bool
    }
    private var pending: Request?
    private var latest: Request?
    private var generation: UInt64 = 0
    private var rendering = false
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(loader, forURLScheme: "duckpad-preview")
        webView = MarkdownPreviewWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.setAccessibilityIdentifier("duckpad.markdown.preview.content")
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.target = self
        closeButton.action = #selector(closePreview)
        closeButton.setAccessibilityIdentifier("duckpad.markdown.preview.close")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        folderButton.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        folderButton.target = self
        folderButton.action = #selector(allowLocalImages)
        folderButton.setAccessibilityIdentifier("duckpad.markdown.preview.image-access")
        for button in [folderButton, closeButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 26),
                button.heightAnchor.constraint(equalToConstant: 26),
            ])
        }
        let header = NSStackView(views: [title, NSView(), folderButton, closeButton])
        header.orientation = .horizontal
        header.spacing = 4
        for view in [header, webView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: 30),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshLocalization()
        reloadImageAccess()
        webView.loadHTMLString(MarkdownPreviewRenderer.document(body: ""), baseURL: URL(string: "duckpad-preview://assets/"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        title.stringValue = catalog.text("Markdown Preview")
        folderButton.toolTip = catalog.text("Choose an image folder to allow local images in the preview.")
        folderButton.setAccessibilityLabel(catalog.text("Allow Local Images…"))
        closeButton.toolTip = catalog.text("Close Preview") + " (⌃W)"
        closeButton.setAccessibilityLabel(catalog.text("Close Preview"))
    }

    static func rememberImageAccess(_ urls: [URL]) {
        var bookmarks = UserDefaults.standard.array(forKey: "markdownPreview.imageFolders") as? [Data] ?? []
        for url in urls {
            if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks.removeAll { existing in
                    var stale = false
                    let resolved = try? URL(resolvingBookmarkData: existing, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
                    return resolved?.standardizedFileURL.path == url.standardizedFileURL.path
                }
                bookmarks.append(data)
            }
        }
        UserDefaults.standard.set(bookmarks, forKey: "markdownPreview.imageFolders")
    }

    func reloadImageAccess() {
        folderGrants.forEach { $0.stopAccessingSecurityScopedResource() }
        folderGrants.removeAll()
        for data in UserDefaults.standard.array(forKey: "markdownPreview.imageFolders") as? [Data] ?? [] {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() { folderGrants.append(url) }
        }
    }

    func update(source: String, documentURL: URL? = nil) {
        enqueue(.source(source), documentURL: documentURL)
    }

    func update(capture: EditorRecoveryCapture, documentURL: URL?) {
        enqueue(.capture(capture), documentURL: documentURL)
    }

    private func enqueue(_ input: Input, documentURL: URL?, plain: Bool = false) {
        guard !invalidated else { return }
        generation &+= 1
        let request = Request(generation: generation, input: input, documentURL: documentURL, plain: plain)
        pending = request
        latest = request
        renderPending()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        renderPending()
    }

    private func renderPending() {
        guard ready, !rendering, !invalidated, let request = pending else { return }
        rendering = true
        pending = nil
        Task { [weak self] in
            // Materialization owns only this request, never the panel or its WebKit runtime.
            let source = await Task.detached(priority: .utility) { () -> String? in
                switch request.input {
                case .source(let text): return text
                case .capture(let capture):
                    return (try? capture.materializedSnapshot()).flatMap { String(data: $0.utf8, encoding: .utf8) }
                }
            }.value
            guard let self, !self.invalidated else { return }
            guard request.generation == self.generation else {
                self.rendering = false
                self.renderPending()
                return
            }
            // The async overload retains the receiver while JavaScript runs. A weak callback
            // lets closing the panel destroy its WKWebView even during a slow render.
            self.webView.callAsyncJavaScript(
                "await window.duckpadRender(source, documentURL, plain); return true;",
                arguments: ["source": source ?? L10n.text("Markdown preview could not be rendered."),
                            "documentURL": request.documentURL?.absoluteString ?? "",
                            "plain": request.plain || source == nil], in: nil, in: .page
            ) { [weak self] result in
                guard let self, !self.invalidated else { return }
                if case .failure = result {
                    self.title.stringValue = L10n.text("Markdown preview could not be rendered.")
                }
                self.rendering = false
                self.renderPending()
            }
        }
    }

    func showMessage(_ message: String) { enqueue(.source(message), documentURL: nil, plain: true) }

    @objc private func allowLocalImages() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.message = L10n.text("Choose the folder containing this document’s images.")
        picker.directoryURL = latest?.documentURL?.deletingLastPathComponent()
        guard picker.runModal() == .OK, let url = picker.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        Self.rememberImageAccess([url])
        reloadImageAccess()
        if let request = latest { enqueue(request.input, documentURL: request.documentURL, plain: request.plain) }
    }

    func invalidate() {
        invalidated = true
        generation &+= 1
        pending = nil
        latest = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        loader.invalidate()
        folderGrants.forEach { $0.stopAccessingSecurityScopedResource() }
        folderGrants.removeAll()
        onClose = nil
    }

    @objc private func closePreview() { onClose?() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, MarkdownPreviewRenderer.isAllowedLink(url) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(navigationAction.navigationType == .other
                        && ["about", "duckpad-preview"].contains(navigationAction.request.url?.scheme ?? "") ? .allow : .cancel)
    }
}
