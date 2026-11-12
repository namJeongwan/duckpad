import AppKit
import WebKit

/// Renders into a nonpersistent WebKit page; document source is passed as data.
@MainActor final class DiagramWebRenderer: NSObject, WKNavigationDelegate {
    private let mermaidRuntime: String?
    private var web: WKWebView?
    private var pending: CheckedContinuation<DiagramRender, any Error>?
    private var timeout: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var input: (kind: String, source: String, dark: Bool)?
    private let deadline: Duration
    init(mermaidRuntime: String? = nil, deadline: Duration = .seconds(30)) {
        self.mermaidRuntime = mermaidRuntime; self.deadline = deadline
    }
    func render(kind: String, source: String, dark: Bool) async throws -> DiagramRender {
        try Task.checkCancellation()
        guard ["svg", "mermaid"].contains(kind), source.utf8.count <= (kind == "svg" ? 32 * 1024 * 1024 : 512 * 1024),
              kind != "mermaid" || mermaidRuntime != nil else { throw DiagramFailure("invalidInput") }
        cancel()
        let token = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation; input = (kind, source, dark)
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                if let mermaidRuntime {
                    configuration.userContentController.addUserScript(WKUserScript(source: mermaidRuntime, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                }
                configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
                let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
                web = view; view.navigationDelegate = self
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: self?.deadline ?? .seconds(30)) } catch { return }
                    self?.finish(.failure(DiagramFailure("timeout")), generation: token)
                }
                view.loadHTMLString("""
                <!doctype html><html><head><meta charset="utf-8">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; base-uri 'none'; form-action 'none'">
                <style>html,body{margin:0;padding:0;overflow:hidden}svg{display:block}</style></head>
                <body><div id="diagram"></div></body></html>
                """, baseURL: nil)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), generation: token) } }
    }
    func cancel() {
        finish(.failure(CancellationError()), generation: generation)
        generation &+= 1
    }
    private func finish(_ result: Result<DiagramRender, any Error>, generation token: UInt64) {
        guard token == generation else { return }
        let continuation = pending; pending = nil
        timeout?.cancel(); timeout = nil
        web?.navigationDelegate = nil; web?.stopLoading()
        web?.configuration.userContentController.removeAllUserScripts()
        web = nil; input = nil
        continuation?.resume(with: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web, let input, pending != nil else { return }
        let token = generation
        webView.callAsyncJavaScript("return await window.duckpadRenderDiagram(kind, source, dark)",
                                   arguments: ["kind": input.kind, "source": input.source, "dark": input.dark],
                                   in: nil, in: .page) { [weak self, weak webView] result in
            MainActor.assumeIsolated {
                guard let self, let webView, webView === self.web, token == self.generation else { return }
                do {
                    let value = try result.get()
                    guard let payload = value as? [String: Any], let svg = payload["svg"] as? String,
                          let width = payload["width"] as? Double, let height = payload["height"] as? Double,
                          width.isFinite, height.isFinite, width > 0, height > 0, width <= 1_000_000, height <= 1_000_000,
                          svg.utf8.count <= 32 * 1024 * 1024 else { throw DiagramFailure("renderFailed") }
                    webView.setFrameSize(NSSize(width: width, height: height))
                    let snapshot = WKSnapshotConfiguration()
                    snapshot.rect = webView.bounds
                    snapshot.afterScreenUpdates = false
                    let pixelWidth = min(width, 4096, 8192 * width / height, sqrt(16_000_000 * width / height))
                    let pixelHeight = pixelWidth * height / width
                    guard pixelWidth >= 1, pixelHeight >= 1 else { throw DiagramFailure("outputLimit") }
                    let backingScale = max(1, NSScreen.screens.map(\.backingScaleFactor).max() ?? 1)
                    snapshot.snapshotWidth = NSNumber(value: pixelWidth / backingScale)
                    webView.takeSnapshot(with: snapshot) { [weak self, weak webView] image, error in
                        MainActor.assumeIsolated {
                            guard let self, let webView, webView === self.web, token == self.generation else { return }
                            guard error == nil, let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                                  cg.width <= 8192, cg.height <= 8192, cg.width * cg.height <= 16_000_000,
                                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]), png.count <= 32 * 1024 * 1024 else {
                                self.finish(.failure(DiagramFailure("renderFailed")), generation: token); return
                            }
                            self.finish(.success(.init(svg: Data(svg.utf8), png: png, width: cg.width, height: cg.height)), generation: token)
                        }
                    }
                } catch { self.finish(.failure(DiagramFailure("renderFailed", error.localizedDescription)), generation: token) }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if webView === web { finish(.failure(DiagramFailure("renderFailed", error.localizedDescription)), generation: generation) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if webView === web { finish(.failure(DiagramFailure("renderFailed", error.localizedDescription)), generation: generation) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === web { finish(.failure(DiagramFailure("renderFailed")), generation: generation) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    private static let script = #"""
    window.duckpadRenderDiagram = async (kind, source, dark) => {
      let value = source;
      if (kind === 'mermaid') {
        const engine = window.duckpadMermaid;
        engine.initialize({startOnLoad:false, securityLevel:'strict', htmlLabels:false,
          theme:dark?'dark':'default', maxTextSize:524288, maxEdges:5000, suppressErrorRendering:true,
          secure:['secure','securityLevel','startOnLoad','htmlLabels','maxTextSize','maxEdges','suppressErrorRendering']});
        value = (await engine.render('duckpad-diagram', source)).svg;
      }
      const parsed = new DOMParser().parseFromString(value, 'image/svg+xml');
      if (parsed.querySelector('parsererror') || parsed.documentElement.localName !== 'svg') throw new Error('Invalid SVG');
      const svg = document.importNode(parsed.documentElement, true);
      for (const element of [svg, ...svg.querySelectorAll('*')]) {
        if (['script','iframe','object','embed','audio','video'].includes(element.localName)) { element.remove(); continue; }
        for (const attribute of [...element.attributes]) {
          if (/^on/i.test(attribute.name) || ['href','xlink:href','src'].includes(attribute.name) && !attribute.value.startsWith('data:') && !attribute.value.startsWith('#')) element.removeAttribute(attribute.name);
        }
      }
      const target = document.getElementById('diagram'); target.replaceChildren(svg);
      const box = svg.viewBox.baseVal;
      const width = box.width || svg.width.baseVal.value || svg.getBBox().width;
      const height = box.height || svg.height.baseVal.value || svg.getBBox().height;
      if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0 || width > 1000000 || height > 1000000) throw new Error('Invalid diagram dimensions');
      svg.setAttribute('width', String(width)); svg.setAttribute('height', String(height));
      document.documentElement.style.colorScheme = dark?'dark':'light';
      document.body.style.background = dark?'#25292f':'#ffffff';
      await document.fonts.ready;
      await new Promise(resolve => setTimeout(resolve, 16));
      return {svg:new XMLSerializer().serializeToString(svg), width, height};
    };
    """#
}
