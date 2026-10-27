import AppKit
import DuckpadApplication
import DuckpadLocalization
import WebKit

@MainActor
final class CodeMirrorEditorView: NSView, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    let webView: WKWebView
    private let loader: MarkdownEditorResourceLoader
    private let mode = NSSegmentedControl()
    private let images = NSButton()
    private let imageAccess: (any MarkdownImageAccess)?
    private var grants: [URL] = []
    private var configuration: [String: Any] = [:]
    private(set) var ready = false
    private(set) var isLive = true
    private(set) var isComposing = false
    private(set) var lastScriptError: String?
    private var invalidated = false
    private var scriptQueue: [(String, [String: Any])] = []
    private var scriptTask: Task<Void, Never>?
    private var wantsFocus = false
    private var appliedTheme: EditorThemePalette?
    private let messageProxy = MarkdownEditorMessageProxy()
    var onMessage: (([String: Any]) -> Bool)?
    var onModeChange: (() -> Void)?
    var onNeedsReload: (() -> Void)?

    init(reader: (any PreviewResourceReading)?, imageAccess: (any MarkdownImageAccess)?) {
        self.imageAccess = imageAccess
        loader = MarkdownEditorResourceLoader(reader: reader)
        let settings = WKWebViewConfiguration()
        settings.websiteDataStore = .nonPersistent()
        settings.setURLSchemeHandler(loader, forURLScheme: "duckpad-editor")
        webView = MarkdownEditorWebView(frame: .zero, configuration: settings)
        super.init(frame: .zero)
        messageProxy.owner = self
        settings.userContentController.addScriptMessageHandler(messageProxy, contentWorld: .page, name: "duckpadEditor")
        webView.navigationDelegate = self
        webView.setAccessibilityIdentifier("duckpad.markdown.editor.content")
        mode.segmentCount = 2
        mode.trackingMode = .selectOne
        mode.selectedSegment = 1
        mode.target = self; mode.action = #selector(toggleMarkdownMode(_:))
        mode.setAccessibilityIdentifier("duckpad.markdown.editor.mode")
        images.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        images.target = self; images.action = #selector(allowImages)
        images.isBordered = false
        images.toolTip = L10n.text("Allow Local Images…")
        images.setAccessibilityLabel(L10n.text("Allow Local Images…"))
        let header = NSStackView(views: [NSView(), mode, images])
        header.orientation = .horizontal; header.spacing = 10
        for child in [header, webView] {
            child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.heightAnchor.constraint(equalToConstant: 34),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor), webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshLocalization()
        grants = imageAccess?.acquire() ?? []
        loadPage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func loadPage() {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none';script-src duckpad-editor:;style-src duckpad-editor: 'unsafe-inline';img-src duckpad-editor: data:;font-src duckpad-editor:;connect-src 'none';base-uri 'none';form-action 'none'">
        <link rel="stylesheet" href="duckpad-editor://assets/katex.css"><link rel="stylesheet" href="duckpad-editor://assets/editor.css"></head><body><div id="editor"></div>
        <script src="duckpad-editor://assets/editor.js"></script></body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "duckpad-editor://assets/"))
    }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        images.toolTip = catalog.text("Allow Local Images…")
        images.setAccessibilityLabel(catalog.text("Allow Local Images…"))
        mode.setLabel(catalog.text("Markdown Source Mode"), forSegment: 0)
        mode.setLabel(catalog.text("Markdown Live Preview"), forSegment: 1)
        configure(["labels": ["copy": catalog.text("Copy"), "cut": catalog.text("Cut"),
            "paste": catalog.text("Paste"), "selectAll": catalog.text("Select All"),
            "insertRow": catalog.text("Insert Row Below"), "insertColumn": catalog.text("Insert Column Right"),
            "deleteRow": catalog.text("Delete Row"), "deleteColumn": catalog.text("Delete Column"),
            "tableCell": catalog.text("Table cell %1$d, %2$d"), "tableOptions": catalog.text("Table Options"),
            "mermaidDiagram": catalog.text("Mermaid Diagram"), "editSource": catalog.text("Edit Source"),
            "renderingDiagram": catalog.text("Rendering diagram…"),
            "invalidDiagram": catalog.text("Diagram incomplete. Edit the source to continue.")]])
    }

    func load(_ values: [String: Any]) {
        configuration.merge(values) { _, new in new }
        configuration["live"] = isLive
        guard ready else { return }
        call("load", arguments: configuration)
    }

    func configure(_ values: [String: Any]) {
        let changed = values.filter { key, value in
            guard let previous = configuration[key] else { return true }
            return !NSDictionary(dictionary: ["value": previous]).isEqual(to: ["value": value])
        }
        guard !changed.isEmpty else { return }
        configuration.merge(changed) { _, new in new }
        guard ready else { return }
        call("configure", arguments: changed)
    }

    func applyTheme(_ palette: EditorThemePalette) {
        guard appliedTheme != palette else { return }
        appliedTheme = palette
        let dark = palette == .dark || palette == .highContrastDark
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let colors = palette.colors
        func hex(_ value: Int) -> String { String(format: "#%06x", value) }
        func native(_ value: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                    green: CGFloat((value >> 8) & 255) / 255,
                    blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        func resolved(_ color: NSColor) -> String {
            var value = ""
            effectiveAppearance.performAsCurrentDrawingAppearance {
                if let rgb = color.usingColorSpace(.sRGB) {
                    value = hex((Int((rgb.redComponent * 255).rounded()) << 16)
                        | (Int((rgb.greenComponent * 255).rounded()) << 8)
                        | Int((rgb.blueComponent * 255).rounded()))
                }
            }
            return value
        }
        wantsLayer = true
        layer?.backgroundColor = native(colors.editor).cgColor
        webView.underPageBackgroundColor = native(colors.editor)
        configure(["colors": ["bg": hex(colors.editor), "fg": hex(colors.foreground),
            "muted": hex(colors.muted), "border": hex(colors.border), "code": hex(colors.panel),
            "selection": hex(colors.selection), "link": resolved(.linkColor), "accent": resolved(.controlAccentColor),
            "syntax-keyword": hex(colors.keyword), "syntax-comment": hex(colors.comment),
            "syntax-number": hex(colors.number), "syntax-string": hex(colors.string),
            "syntax-operation": hex(colors.operation), "error": resolved(.systemRed)]])
    }

    func setLive(_ enabled: Bool) {
        guard !isComposing else { return }
        isLive = enabled; mode.selectedSegment = enabled ? 1 : 0
        configure(["live": enabled]); onModeChange?()
    }

    @objc private func toggleMarkdownMode(_ sender: NSSegmentedControl) { setLive(mode.selectedSegment == 1); focus() }

    func reloadImageAccess() {
        guard !invalidated, let imageAccess else { return }
        imageAccess.release(grants)
        grants = imageAccess.acquire()
        call("reloadImages", arguments: [:])
    }

    @objc private func allowImages() {
        guard let imageAccess, let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            imageAccess.remember(panel.urls)
            self.reloadImageAccess()
            self.focus()
        }
    }

    func focus() {
        wantsFocus = true
        guard ready else { return }
        window?.makeFirstResponder(webView)
        call("focus", arguments: [:])
    }
    var hasEditorFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    func call(_ method: String, arguments: [String: Any]) {
        if method == "nativeSelection" {
            configuration["anchor"] = arguments["anchor"]; configuration["caret"] = arguments["caret"]
            configuration["ranges"] = arguments["ranges"]; configuration["mainIndex"] = arguments["mainIndex"]
        }
        guard ready, !invalidated else { return }
        // Method names are private constants. Payloads stay structured arguments.
        scriptQueue.append((method, arguments))
        guard scriptTask == nil else { return }
        scriptTask = Task { [weak self] in
            guard let self else { return }
            while !self.scriptQueue.isEmpty, !self.invalidated {
                var (method, payload) = self.scriptQueue.removeFirst()
                if method == "applyHostEdit" {
                    var edits = [payload]
                    while let next = self.scriptQueue.first, next.0 == "applyHostEdit" {
                        edits.append(self.scriptQueue.removeFirst().1)
                    }
                    // Native Undo and multi-range commands publish several
                    // deltas. Render their final table layout in one update.
                    method = "applyHostEdits"; payload = ["edits": edits]
                }
                do {
                    _ = try await self.webView.callAsyncJavaScript("return window.DuckpadEditor.\(method)(payload)",
                        arguments: ["payload": payload], in: nil, contentWorld: .page)
                } catch { self.lastScriptError = String(describing: error) }
            }
            self.scriptTask = nil
        }
    }

    func flush() async -> Bool {
        guard !invalidated else { return false }
        guard ready else { return true } // Native document remains authoritative while loading.
        await scriptTask?.value
        do {
            return try await webView.callAsyncJavaScript("return await window.DuckpadEditor.flush()", arguments: [:], in: nil, contentWorld: .page) as? Bool == true
        } catch { return false }
    }

    func command(_ command: String) {
        call("nativeCommand", arguments: ["command": command])
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard !invalidated, message.frameInfo.isMainFrame, let payload = message.body as? [String: Any], let type = payload["type"] as? String else {
            replyHandler(nil, "Invalid editor message"); return
        }
        if type == "ready" {
            ready = true; load(configuration)
            if wantsFocus && window != nil { focus() }
            replyHandler(["accepted": true], nil); return
        }
        guard let generation = payload["generation"] as? Int, generation == configuration["generation"] as? Int else {
            replyHandler(nil, "Stale editor generation"); return
        }
        if type == "clipboardRead" {
            replyHandler(["text": NSPasteboard.general.string(forType: .string) ?? ""], nil); return
        }
        if type == "composition" {
            isComposing = payload["active"] as? Bool == true; mode.isEnabled = !isComposing
        }
        let accepted = onMessage?(payload) ?? (type == "barrier" || type == "composition")
        replyHandler(["accepted": accepted], nil)
        if !accepted { onNeedsReload?() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; isComposing = false; onNeedsReload?(); loadPage()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        decisionHandler(navigationAction.navigationType == .other && (scheme == "about" || scheme == "duckpad-editor") ? .allow : .cancel)
    }

    func invalidate() {
        invalidated = true; loader.invalidate(); scriptTask?.cancel(); scriptQueue.removeAll()
        webView.stopLoading(); webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "duckpadEditor", contentWorld: .page)
        imageAccess?.release(grants); grants.removeAll()
        onMessage = nil; onNeedsReload = nil; onModeChange = nil
    }
}

@MainActor
private final class MarkdownEditorMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: CodeMirrorEditorView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let owner else { replyHandler(nil, "Editor has been retired"); return }
        owner.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}
